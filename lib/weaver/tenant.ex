defmodule Weaver.Tenant do
  @moduledoc """
  One tenant's processes, and the one that holds its state.

  ## Where they run

  On the node that has the tenant's VM, and nowhere else: their files are in
  the VM, reached over its vsock, and the vsock is a Unix socket on that host.
  So nothing decides where a tenant goes. The VM is somewhere, and its
  processes start beside it. A host that dies takes the VM with it, and there
  is nothing to fail over to.

  Two `:pg` groups (scope `Weaver.PG`) answer "where" from any node:
  `{:vm, t}`, joined by the VM's listener in `Weaver.Calls` for as long as the
  VM exists on that host, and `{:tenant, t}`, joined by this process while it
  runs. Uniqueness needs no cluster-wide lock: only the VM's node starts a
  tenant, and its local `Registry` (`Weaver.Local`) refuses a second.

  ## Started on demand, gone when idle

  `ensure/1` starts the tenant when anything needs it: a browser connecting,
  an API call, a program in the VM calling out. The tenant then counts its
  holders (browser channels that `hold/2` it) and its live sessions and
  terminals; with none of either for `@idle_grace`, the whole tree stops.
  Everything it held is in the VM already, so stopping loses nothing, and
  starting again reads it back.

  ## What it holds

  What the sidebar needs without starting a session: a summary of every
  session, read from their headers at start and kept current from the lobby
  topic; the order the user dragged the directories into
  (`~/.loom/directories.json` in the VM); and the terminal layout, in memory,
  like the terminals themselves.

  ## What it puts in the VM

  Weaver's skills (`priv/skills`), into the tenant's `~/.claude/skills/` and
  `~/.codex/skills/`, every time it starts: they describe the platform, so
  they follow the platform's version. A file that is already the same is
  left alone.
  """
  use GenServer

  require Logger

  alias Weaver.Agent.Directory

  @pg Weaver.PG
  @idle_grace :timer.minutes(10)
  @order_limit 500

  # ── Finding and starting ──────────────────────────────────────────────────

  @doc "The tenant's process, started on its VM's node if it is not running."
  def ensure(t) when is_binary(t) do
    case :pg.get_members(@pg, {:tenant, t}) do
      [pid | _] ->
        {:ok, pid}

      [] ->
        with {:ok, node} <- vm_node(t), do: :erpc.call(node, __MODULE__, :start_here, [t])
    end
  end

  @doc "Which node has the tenant's VM."
  def vm_node(t) do
    case :pg.get_members(@pg, {:vm, t}) do
      [pid | _] -> {:ok, node(pid)}
      [] -> {:error, :no_such_tenant}
    end
  end

  @doc "Whether the tenant exists, that is, has a VM somewhere."
  def exists?(t), do: match?({:ok, _}, vm_node(t))

  @doc false
  def start_here(t) do
    case DynamicSupervisor.start_child(Weaver.Tenants, {Weaver.Tenant.Tree, t}) do
      {:ok, _} -> local(t)
      {:error, {:already_started, _}} -> local(t)
      {:error, _} = error -> error
    end
  end

  defp local(t) do
    case Registry.lookup(Weaver.Local, {:tenant, t}) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_started}
    end
  end

  @doc """
  Run `apply(m, f, a)` on the tenant's node, starting the tenant first. How
  anything outside it (a channel, a controller) reaches what is inside.
  """
  def at(t, m, f, a) do
    with {:ok, pid} <- ensure(t) do
      if node(pid) == node(), do: apply(m, f, a), else: :erpc.call(node(pid), m, f, a)
    end
  end

  @doc "Keep the tenant up while `pid` (a browser's channel) lives."
  def hold(t, pid \\ self()), do: call(t, {:hold, pid})

  def via(t, what), do: {:via, Registry, {Weaver.Local, {what, t}}}

  # ── State ─────────────────────────────────────────────────────────────────

  @doc "Every session's summary, oldest first."
  def sessions(t), do: call(t, :sessions)

  def directory_order(t), do: call(t, :directory_order)

  @doc "Replace the directory order, as the sidebar sends it after a drag."
  def put_directory_order(t, paths), do: call(t, {:put_directory_order, paths})

  @doc "A directory moved: its entry in the order follows."
  def rebase_directory_order(t, from, to), do: call(t, {:rebase_directory_order, from, to})

  def layout(t), do: call(t, :layout)
  def put_layout(t, layout), do: call(t, {:put_layout, layout})

  def lobby_topic(t), do: "tenant:#{t}:agents"

  @doc "Where sessions announce a finished turn, for `Weaver.Push`: `{:turn_ended, id, summary}`."
  def turns_topic(t), do: "tenant:#{t}:turns"

  defp call(t, msg) do
    with {:ok, pid} <- ensure(t), do: GenServer.call(pid, msg)
  end

  def start_link(t), do: GenServer.start_link(__MODULE__, t, name: via(t, :tenant))

  @impl true
  def init(t) do
    :pg.join(@pg, {:tenant, t}, self())
    Phoenix.PubSub.subscribe(Weaver.PubSub, lobby_topic(t))

    sessions = Map.new(Weaver.Agent.Store.list_summaries(t), &{&1.id, &1})
    Logger.info("Weaver.Tenant #{t} started, #{map_size(sessions)} sessions")

    state = %{
      tenant: t,
      sessions: sessions,
      order: read_order(t),
      layout: %{tabs: [], active_tab: nil},
      holders: %{},
      idle: nil
    }

    {:ok, check_idle(state), {:continue, :skills}}
  end

  @impl true
  def handle_continue(:skills, state) do
    install_skills(state.tenant)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sessions, _from, state) do
    {:reply, state.sessions |> Map.values() |> Enum.sort_by(& &1.created_at), state}
  end

  def handle_call(:directory_order, _from, state), do: {:reply, state.order, state}

  def handle_call({:put_directory_order, paths}, _from, state)
      when is_list(paths) and length(paths) <= @order_limit do
    normalized = Enum.map(paths, &Directory.normalize/1)

    if Enum.all?(normalized, &match?({:ok, _}, &1)),
      do: {:reply, :ok, update_order(state, for({:ok, p} <- normalized, do: p))},
      else: {:reply, {:error, :invalid_directory}, state}
  end

  def handle_call({:put_directory_order, _}, _from, state),
    do: {:reply, {:error, :invalid_directory}, state}

  def handle_call({:rebase_directory_order, from, to}, _from, state) do
    paths =
      Enum.map(state.order, fn p ->
        case Directory.rebase(p, from, to) do
          {:ok, new} -> new
          :unchanged -> p
        end
      end)

    {:reply, :ok, update_order(state, paths)}
  end

  def handle_call(:layout, _from, state), do: {:reply, state.layout, state}

  def handle_call({:put_layout, layout}, _from, state),
    do: {:reply, :ok, %{state | layout: layout}}

  def handle_call({:hold, pid}, _from, state) do
    ref = Process.monitor(pid)
    {:reply, :ok, cancel_idle(%{state | holders: Map.put(state.holders, ref, pid)})}
  end

  @impl true
  def handle_info({:agent_summary, summary}, state) do
    sessions =
      Map.update(state.sessions, summary.id, summary, fn old ->
        if (summary[:seq] || 0) >= (old[:seq] || 0), do: summary, else: old
      end)

    {:noreply, %{state | sessions: sessions}}
  end

  def handle_info({:agent_removed, id}, state) do
    {:noreply, %{state | sessions: Map.delete(state.sessions, id)}}
  end

  def handle_info({:directory_order, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) when is_map_key(state.holders, ref) do
    {:noreply, check_idle(%{state | holders: Map.delete(state.holders, ref)})}
  end

  def handle_info(:idle, state) do
    state = %{state | idle: nil}

    cond do
      state.holders != %{} ->
        {:noreply, state}

      busy?(state.tenant) ->
        # Sessions and terminals let themselves go once nobody is using them;
        # look again after they have had the chance.
        {:noreply, check_idle(state)}

      true ->
        Logger.info("Weaver.Tenant #{state.tenant} idle, stopping")
        tree = GenServer.whereis(via(state.tenant, :tree))
        spawn(fn -> DynamicSupervisor.terminate_child(Weaver.Tenants, tree) end)
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp busy?(t) do
    Enum.any?([:sessions, :terminals], fn sup ->
      DynamicSupervisor.count_children(via(t, sup)).active > 0
    end)
  end

  defp check_idle(%{holders: holders} = state) when holders != %{}, do: state

  defp check_idle(%{idle: nil} = state),
    do: %{state | idle: Process.send_after(self(), :idle, @idle_grace)}

  defp check_idle(state), do: state

  defp cancel_idle(%{idle: nil} = state), do: state

  defp cancel_idle(state) do
    Process.cancel_timer(state.idle)
    %{state | idle: nil}
  end

  # ── Skills ────────────────────────────────────────────────────────────────

  defp install_skills(t) do
    source = Application.app_dir(:weaver, "priv/skills")

    for file <- Path.wildcard(Path.join(source, "**/*")),
        File.regular?(file),
        data = File.read!(file),
        rel = Path.relative_to(file, source),
        target <- [
          Path.join([Weaver.FS.home(), ".claude/skills", rel]),
          Path.join([Weaver.FS.home(), ".codex/skills", rel])
        ],
        Weaver.FS.read(t, target) != {:ok, data} do
      Weaver.FS.write(t, target, data)
    end
  rescue
    # A VM that is not running gets them the next time.
    error -> Logger.warning("Weaver.Tenant #{t} could not install skills: #{inspect(error)}")
  end

  # ── Directory order ───────────────────────────────────────────────────────

  defp order_path, do: Path.join(Weaver.Agent.Store.home(), "directories.json")

  defp read_order(t) do
    with {:ok, body} <- Weaver.FS.read(t, order_path()),
         {:ok, %{"order" => paths}} when is_list(paths) <- Jason.decode(body) do
      Enum.filter(paths, &is_binary/1)
    else
      _ -> []
    end
  end

  # A merge leaves two entries the same: the first keeps its place.
  defp update_order(state, paths) do
    paths = paths |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if paths == state.order do
      state
    else
      Weaver.FS.write(state.tenant, order_path(), Jason.encode!(%{order: paths}, pretty: true))

      Phoenix.PubSub.broadcast(
        Weaver.PubSub,
        lobby_topic(state.tenant),
        {:directory_order, paths}
      )

      %{state | order: paths}
    end
  end
end
