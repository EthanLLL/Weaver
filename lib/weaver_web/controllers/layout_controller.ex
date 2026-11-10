defmodule WeaverWeb.LayoutController do
  @moduledoc "The terminal layout (Loom's), held by the tenant, reconciled against live terminals."
  use WeaverWeb, :controller

  import WeaverWeb.At

  def show(conn, _params), do: json(conn, at(conn, __MODULE__, :reconciled, []))

  def update(conn, params) do
    layout = %{
      tabs:
        Enum.map(params["tabs"] || [], fn tab -> %{id: tab["id"], panes: tab["panes"] || []} end),
      active_tab: params["active_tab"]
    }

    :ok = Weaver.Tenant.put_layout(conn.assigns.tenant, layout)
    show(conn, params)
  end

  @doc false
  # On the tenant's node: drop panes whose shell has gone, and tabs left empty.
  def reconciled(t) do
    %{tabs: tabs, active_tab: active} = Weaver.Tenant.layout(t)

    live =
      tabs
      |> Enum.map(fn tab ->
        %{id: tab.id, panes: Enum.filter(tab.panes, &Weaver.Terminal.exists?(t, &1))}
      end)
      |> Enum.reject(&(&1.panes == []))

    active =
      if Enum.any?(live, &(&1.id == active)),
        do: active,
        else: live |> List.first() |> then(&(&1 && &1.id))

    %{tabs: live, active_tab: active}
  end
end
