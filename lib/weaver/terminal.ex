defmodule Weaver.Terminal do
  @moduledoc """
  A tenant's terminals: Loom's `Loom.Terminal`, per tenant. Each is a login
  shell in the VM, as its user, on a pty (`Weaver.Terminal.Session`), and
  outlives the browsers attached to it. Runs on the tenant's node.
  """

  alias Weaver.Terminal.Session
  alias Weaver.Tenant

  def start_session(t, id, opts \\ []) do
    spec = {Session, [tenant: t, id: id] ++ opts}

    case DynamicSupervisor.start_child(Tenant.via(t, :terminals), spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def exists?(t, id), do: Registry.lookup(Weaver.Local, {:terminal, t, id}) != []

  def stop_session(t, id) do
    case Registry.lookup(Weaver.Local, {:terminal, t, id}) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Tenant.via(t, :terminals), pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Every live terminal's info, oldest first."
  def list_sessions(t) do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Tenant.via(t, :terminals)),
        is_pid(pid),
        info = safe_info(pid),
        info != nil do
      info
    end
    |> Enum.sort_by(& &1.created_at)
  end

  defdelegate subscribe(t, id, pid, size \\ nil), to: Session
  defdelegate send_input(t, id, pid, data), to: Session
  defdelegate resize(t, id, pid, cols, rows), to: Session
  defdelegate info(t, id), to: Session

  defp safe_info(pid) do
    GenServer.call(pid, :info)
  catch
    :exit, _ -> nil
  end
end
