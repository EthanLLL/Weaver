defmodule Weaver.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {DynamicSupervisor, name: Weaver.Execs, strategy: :one_for_one},
      Weaver.Peers
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Weaver.Supervisor)
  end
end
