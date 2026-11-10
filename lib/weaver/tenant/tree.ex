defmodule Weaver.Tenant.Tree do
  @moduledoc """
  A tenant's processes, under `Weaver.Tenants` on its VM's node: its sessions,
  its terminals, and `Weaver.Tenant`. Stopped whole when the tenant idles.
  """
  use Supervisor, restart: :temporary

  alias Weaver.Tenant

  def start_link(t), do: Supervisor.start_link(__MODULE__, t, name: Tenant.via(t, :tree))

  @impl true
  def init(t) do
    children = [
      # One bad session must not take the rest down by tripping the default
      # restart intensity; see Loom's note on the same supervisor.
      Supervisor.child_spec(
        {DynamicSupervisor,
         name: Tenant.via(t, :sessions), strategy: :one_for_one, max_restarts: 20, max_seconds: 5},
        id: :sessions
      ),
      Supervisor.child_spec(
        {DynamicSupervisor, name: Tenant.via(t, :terminals), strategy: :one_for_one},
        id: :terminals
      ),
      {Tenant, t}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
