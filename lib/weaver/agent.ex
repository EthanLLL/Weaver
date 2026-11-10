defmodule Weaver.Agent do
  @moduledoc """
  A tenant's agent sessions: Loom's `Loom.Agent`, per tenant.

  Every function here runs on the tenant's node, where its sessions are;
  from anywhere else, go through `Weaver.Tenant.at/4`. Sessions start when
  something needs them (`ensure/2`) and stop when nothing does (see
  `Weaver.Agent.Session`); the list of them is the tenant's
  (`Weaver.Tenant.sessions/1`), whether their processes run or not.
  """

  alias Weaver.Agent.{Directory, Session, Store}
  alias Weaver.Tenant

  @doc "Start a new session `id`. `:backend` is required (`:claude_code`)."
  def start_session(t, id, opts \\ []) do
    spec = {Session, [tenant: t, id: id] ++ opts}

    case DynamicSupervisor.start_child(Tenant.via(t, :sessions), spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  @doc "The session's process, restored from the VM if it is not running."
  def ensure(t, id) do
    case Registry.lookup(Weaver.Local, {:session, t, id}) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        if Store.valid_id?(id) do
          case start_session(t, id, restore: true) do
            {:ok, pid} -> {:ok, pid}
            {:error, {:no_such_session, _}} -> {:error, :not_found}
            {:error, reason} -> {:error, reason}
          end
        else
          {:error, :not_found}
        end
    end
  end

  def exists?(t, id), do: match?({:ok, _}, ensure(t, id))

  @doc "A fresh session titled `title`, with `prompt` submitted; `{:ok, id}`."
  def new_session(t, title, prompt, opts \\ []) do
    id = new_id()

    with {:ok, _} <- start_session(t, id, backend: :claude_code, title: title),
         {:ok, _} <- Session.submit(t, id, prompt, Keyword.take(opts, [:origin])) do
      {:ok, id}
    end
  end

  def new_id, do: "a_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @doc "Stop a session and move its history to the VM's trash."
  def delete_session(t, id) do
    case Registry.lookup(Weaver.Local, {:session, t, id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Tenant.via(t, :sessions), pid)
      [] -> :ok
    end

    Phoenix.PubSub.broadcast(Weaver.PubSub, Tenant.lobby_topic(t), {:agent_removed, id})
    Store.delete_session(t, id)
  end

  @doc """
  Move or rename a directory of the session list: every session at `from` or
  under it gets `from` swapped for `to`. See `Weaver.Agent.Directory`.
  """
  def move_directory(t, from, to) do
    with {:ok, from} <- Directory.normalize(from),
         {:ok, to} <- Directory.normalize(to),
         :ok <- movable(from, to) do
      for %{id: id, directory: dir} <- Tenant.sessions(t),
          {:ok, new} <- [Directory.rebase(dir, from, to)],
          do: move(t, id, new)

      Tenant.rebase_directory_order(t, from, to)
    end
  end

  defp movable("", _to), do: {:error, :root}

  defp movable(from, to) do
    if Directory.within?(to, from) and to != from, do: {:error, :into_itself}, else: :ok
  end

  def list_sessions(t), do: Tenant.sessions(t)

  @doc "Let every running session's backend go, so changed config is read (`/reload`)."
  def reload_backends(t) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Tenant.via(t, :sessions)),
        is_pid(pid),
        do: send(pid, :reload_backend)

    :ok
  end

  def submit(t, id, text, opts \\ []), do: on(t, id, fn -> Session.submit(t, id, text, opts) end)
  def interrupt(t, id), do: on(t, id, fn -> Session.interrupt(t, id) end)
  def drop_queued(t, id, index), do: on(t, id, fn -> Session.drop_queued(t, id, index) end)
  def rename(t, id, title), do: on(t, id, fn -> Session.rename(t, id, title) end)
  def move(t, id, directory), do: on(t, id, fn -> Session.move(t, id, directory) end)
  def info(t, id), do: on(t, id, fn -> Session.info(t, id) end)

  def attach(t, id, since_seq, watcher),
    do: on(t, id, fn -> Session.attach(t, id, since_seq, watcher) end)

  defdelegate topic(t, id), to: Session

  defp on(t, id, fun) do
    with {:ok, _} <- ensure(t, id), do: fun.()
  end
end
