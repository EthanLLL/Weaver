defmodule Weaver.Nodes do
  @moduledoc """
  A tenant's own machines (a Mac, a WSL box) that their agents can run
  commands on: Loom's `Loom.Nodes`, one per tenant, in the tenant's tree.

  Each runs `weaver-node daemon` (`node/`), which dials the tenant's host,
  `wss://<tenant>.luozhen.cloud/node`, and joins `WeaverWeb.NodeChannel`. An
  agent in the VM reaches it with `weaver node …` (`guest/node.go`), a call
  that `Weaver.Calls.Node` relays to the device's channel.

  ## What is where

  - **Registered devices** are the tenant's, in their VM's
    `~/.loom/nodes.json`: names, what each said about itself, and its
    token's SHA-256, never the token.
  - **Who is online** is the channels themselves: each joins the `:pg` group
    `{:device, t, id}` (any node, wherever Cloudflare sent it). A daemon is
    always connected, so a device must not hold the tenant up the way a
    browser does: this process may stop while devices stay online, and
    finds them in the group when it starts again.
  - **Install codes** are in memory, good for `@install_ttl`. Redeeming one
    mints the device's token and kills the previous one, as in Loom.

  ## Broadcasts

  On the tenant's lobby topic, for the sidebar: `{:node_summary, summary}`
  and `{:node_removed, id}`. On `nodes_topic/1`, `{:node_online, id}`, for a
  request waiting on a device that is reconnecting.
  """
  use GenServer

  require Logger

  alias Weaver.Tenant

  @pg Weaver.PG
  @persisted ~w(id name token_hash created_at os arch hostname version last_seen_at)a
  @install_ttl :timer.hours(1)
  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/

  def start_link(t), do: GenServer.start_link(__MODULE__, t, name: Tenant.via(t, :nodes))

  def nodes_topic(t), do: "tenant:#{t}:nodes"

  @doc "The `:pg` group a device's channel is in while it is connected."
  def group(t, id), do: {:device, t, id}

  # Each of these runs on the tenant's node; callers go through `Tenant.at/4`.

  @doc "Every device, oldest first, with `online`."
  def list(t), do: call(t, :list)

  @doc "Register a device. `{:ok, summary, install_code}` or `{:error, reason}`."
  def create(t, name), do: call(t, {:create, name})

  def rename(t, id, name), do: call(t, {:rename, id, name})

  @doc "Forget a device: its token stops working and a live connection is dropped."
  def delete(t, id), do: call(t, {:delete, id})

  @doc "A fresh one-time install code for a registered device."
  def install_code(t, id), do: call(t, {:install_code, id})

  @doc "Trade an install code for the device's new token: `{:ok, summary, token}`."
  def redeem(t, code), do: call(t, {:redeem, code})

  @doc "The device a token belongs to: `{:ok, id}` or `:error`."
  def authenticate(t, token), do: call(t, {:authenticate, token})

  @doc """
  A device's channel `pid` has joined, with what the device says about
  itself. A previous connection for the same device is told to stop. The
  channel joins the device's group itself once this returns.
  """
  def connected(t, id, pid, info), do: call(t, {:connected, id, pid, info})

  @doc "The channel for a device, by name: `{:ok, pid}`, `{:offline, summary}` or `:unknown`."
  def lookup(t, name), do: call(t, {:lookup, name})

  @doc """
  Like `lookup/2`, but an offline device gets `timeout` ms to come back: a
  Mac just woken from sleep is usually seconds from reconnecting.
  """
  def await(t, name, timeout) do
    Phoenix.PubSub.subscribe(Weaver.PubSub, nodes_topic(t))

    try do
      wait(t, name, System.monotonic_time(:millisecond) + timeout)
    after
      Phoenix.PubSub.unsubscribe(Weaver.PubSub, nodes_topic(t))
    end
  end

  defp wait(t, name, deadline) do
    case lookup(t, name) do
      {:offline, _summary} = offline ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
          {:node_online, _id} -> wait(t, name, deadline)
        after
          max(remaining, 0) -> offline
        end

      other ->
        other
    end
  end

  defp call(t, msg), do: GenServer.call(Tenant.via(t, :nodes), msg)

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(t) do
    nodes = t |> load() |> Map.new(&{&1.id, &1})
    state = %{tenant: t, nodes: nodes, online: %{}, codes: %{}}

    # Devices that stayed connected while this was not running.
    online =
      for {id, _} <- nodes, pid <- :pg.get_members(@pg, group(t, id)), into: %{} do
        {id, {pid, Process.monitor(pid)}}
      end

    {:ok, %{state | online: online}}
  end

  @impl true
  def handle_call(:list, _from, state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&summary(&1, state))

    {:reply, nodes, state}
  end

  def handle_call({:create, name}, _from, state) do
    with {:ok, name} <- check_name(name, nil, state) do
      node = %{
        id: "n_" <> random(6),
        name: name,
        token_hash: nil,
        created_at: now(),
        os: nil,
        arch: nil,
        hostname: nil,
        version: nil,
        last_seen_at: nil
      }

      state = save(put_in(state.nodes[node.id], node))
      {code, state} = new_code(node.id, state)
      announce(node, state)
      {:reply, {:ok, summary(node, state), code}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:rename, id, name}, _from, state) do
    with {:ok, node} <- fetch(id, state),
         {:ok, name} <- check_name(name, id, state) do
      node = %{node | name: name}
      state = save(put_in(state.nodes[id], node))
      announce(node, state)
      {:reply, {:ok, summary(node, state)}, state}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:delete, id}, _from, state) do
    case fetch(id, state) do
      {:ok, _node} ->
        state = drop_connection(id, state)
        codes = for {_code, {owner, _}} = entry <- state.codes, owner != id, into: %{}, do: entry
        state = save(%{state | nodes: Map.delete(state.nodes, id), codes: codes})

        Phoenix.PubSub.broadcast(
          Weaver.PubSub,
          Tenant.lobby_topic(state.tenant),
          {:node_removed, id}
        )

        {:reply, :ok, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:install_code, id}, _from, state) do
    case fetch(id, state) do
      {:ok, _node} ->
        {code, state} = new_code(id, state)
        {:reply, {:ok, code}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:redeem, code}, _from, state) do
    now_ms = System.monotonic_time(:millisecond)

    with {id, expires} when expires > now_ms <- Map.get(state.codes, code),
         {:ok, node} <- fetch(id, state) do
      token = "wn_" <> random(32)
      node = %{node | token_hash: hash(token)}
      state = %{state | codes: Map.delete(state.codes, code)}
      # The old token is dead; so is a connection made with it.
      state = id |> drop_connection(state) |> then(&save(put_in(&1.nodes[id], node)))
      {:reply, {:ok, summary(node, state), token}, state}
    else
      _ -> {:reply, {:error, :invalid_code}, %{state | codes: Map.delete(state.codes, code)}}
    end
  end

  def handle_call({:authenticate, token}, _from, state) when is_binary(token) do
    hashed = hash(token)

    found =
      Enum.find(state.nodes, fn {_id, node} ->
        node.token_hash != nil and Plug.Crypto.secure_compare(node.token_hash, hashed)
      end)

    case found do
      {id, _node} -> {:reply, {:ok, id}, state}
      nil -> {:reply, :error, state}
    end
  end

  def handle_call({:authenticate, _token}, _from, state), do: {:reply, :error, state}

  def handle_call({:connected, id, pid, info}, _from, state) do
    case fetch(id, state) do
      {:ok, node} ->
        state = drop_connection(id, state)
        ref = Process.monitor(pid)

        node =
          Map.merge(node, %{
            os: info["os"],
            arch: info["arch"],
            hostname: info["hostname"],
            version: info["version"],
            last_seen_at: now()
          })

        state = %{state | online: Map.put(state.online, id, {pid, ref})}
        state = save(put_in(state.nodes[id], node))
        announce(node, state)
        Phoenix.PubSub.broadcast(Weaver.PubSub, nodes_topic(state.tenant), {:node_online, id})
        {:reply, {:ok, summary(node, state)}, state}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:lookup, name}, _from, state) do
    reply =
      case Enum.find(Map.values(state.nodes), &same_name?(&1.name, name)) do
        nil ->
          :unknown

        node ->
          case Map.fetch(state.online, node.id) do
            {:ok, {pid, _ref}} -> {:ok, pid}
            :error -> {:offline, summary(node, state)}
          end
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.online, fn {_id, {_pid, r}} -> r == ref end) do
      {id, _} ->
        state = %{state | online: Map.delete(state.online, id)}

        state =
          case state.nodes do
            %{^id => node} ->
              node = %{node | last_seen_at: now()}
              state = save(put_in(state.nodes[id], node))
              announce(node, state)
              state

            _ ->
              state
          end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp summary(node, state) do
    node
    |> Map.drop([:token_hash])
    |> Map.put(:online, Map.has_key?(state.online, node.id))
  end

  defp announce(node, state) do
    Phoenix.PubSub.broadcast(
      Weaver.PubSub,
      Tenant.lobby_topic(state.tenant),
      {:node_summary, summary(node, state)}
    )
  end

  # Stops the device's channel. The device takes a channel that goes away as
  # a dropped connection and redials, and a dead token is refused at connect.
  defp drop_connection(id, state) do
    case Map.pop(state.online, id) do
      {{pid, ref}, online} ->
        Process.demonitor(ref, [:flush])
        send(pid, :node_replaced)
        %{state | online: online}

      {nil, _} ->
        state
    end
  end

  defp fetch(id, state) do
    case state.nodes do
      %{^id => node} -> {:ok, node}
      _ -> {:error, :not_found}
    end
  end

  defp check_name(name, self_id, state) when is_binary(name) do
    name = String.trim(name)

    cond do
      not Regex.match?(@name_format, name) ->
        {:error, "a name is 1–32 letters, digits, dots, dashes or underscores"}

      Enum.any?(state.nodes, fn {id, node} -> id != self_id and same_name?(node.name, name) end) ->
        {:error, "there is already a device called #{name}"}

      true ->
        {:ok, name}
    end
  end

  defp check_name(_name, _self_id, _state), do: {:error, "a name is required"}

  defp same_name?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(a) == String.downcase(b)

  defp same_name?(_a, _b), do: false

  defp new_code(id, state) do
    code = random(16)
    now_ms = System.monotonic_time(:millisecond)
    # Expired codes go whenever a new one is made; there are only ever a few.
    codes = for {c, {_, e} = v} <- state.codes, e > now_ms, into: %{}, do: {c, v}
    {code, %{state | codes: Map.put(codes, code, {id, now_ms + @install_ttl})}}
  end

  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # ── Storage ─────────────────────────────────────────────────────────────

  defp path, do: Path.join(Weaver.Agent.Store.home(), "nodes.json")

  defp load(t) do
    case Weaver.FS.read(t, path()) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"nodes" => nodes}} when is_list(nodes) ->
            for node <- nodes do
              Map.new(@persisted, fn key -> {key, node[Atom.to_string(key)]} end)
            end

          _ ->
            aside = "#{path()}.bad-#{System.os_time(:second)}"
            Weaver.FS.rename(t, path(), aside)
            Logger.error("Weaver.Nodes #{t} cannot read #{path()}; moved it to #{aside}")
            []
        end

      {:error, :enoent} ->
        []

      # Not "none": saving over it would forget every device.
      {:error, reason} ->
        raise "Weaver.Nodes #{t} cannot read #{path()}: #{inspect(reason)}"
    end
  end

  defp save(state) do
    nodes =
      state.nodes
      |> Map.values()
      |> Enum.sort_by(& &1.created_at)
      |> Enum.map(&Map.take(&1, @persisted))

    Weaver.FS.write!(state.tenant, path(), Jason.encode_to_iodata!(%{nodes: nodes}, pretty: true))
    state
  end
end
