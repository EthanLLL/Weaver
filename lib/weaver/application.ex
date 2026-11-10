defmodule Weaver.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Where tenants and their VMs are, across the cluster (`Weaver.Tenant`).
      %{id: Weaver.PG, start: {:pg, :start_link, [Weaver.PG]}},
      # This node's own names: tenants, their sessions and terminals.
      {Registry, keys: :unique, name: Weaver.Local},
      {Phoenix.PubSub, name: Weaver.PubSub},
      {DynamicSupervisor, name: Weaver.Execs, strategy: :one_for_one},
      # One `Weaver.Tenant.Tree` per tenant whose VM is here and who is in use.
      {DynamicSupervisor, name: Weaver.Tenants, strategy: :one_for_one},
      Weaver.Calls,
      Weaver.Peers,
      WeaverWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Weaver.Supervisor)
  end
end
