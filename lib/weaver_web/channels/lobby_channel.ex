defmodule WeaverWeb.LobbyChannel do
  @moduledoc """
  The session list, pushed instead of polled (Loom's, for the socket's
  tenant). The topic the client joins is `agents`; what it hears is the
  tenant's lobby topic (`Weaver.Tenant.lobby_topic/1`).

  Server → client: join reply `%{sessions, nodes, apps, directory_order}`
  (no devices or apps in Weaver yet), then "session", "removed",
  "directory_order". Client → server: "directory_order", "watching" and
  "search" (not in Weaver yet; search replies `no_rg`).

  Joining holds the tenant up for as long as the channel lives.
  """
  use Phoenix.Channel

  alias Weaver.Tenant

  @impl true
  def join("agents", _params, socket) do
    t = socket.assigns.tenant
    :ok = Phoenix.PubSub.subscribe(Weaver.PubSub, Tenant.lobby_topic(t))
    :ok = Tenant.hold(t)

    {:ok,
     %{
       sessions: Tenant.sessions(t),
       nodes: [],
       apps: [],
       directory_order: Tenant.directory_order(t)
     }, socket}
  end

  @impl true
  def handle_in("directory_order", %{"order" => order}, socket) do
    case Tenant.put_directory_order(socket.assigns.tenant, order) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("search", _params, socket), do: {:reply, {:error, %{reason: "no_rg"}}, socket}
  def handle_in("watching", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:agent_summary, summary}, socket) do
    push(socket, "session", summary)
    {:noreply, socket}
  end

  def handle_info({:agent_removed, id}, socket) do
    push(socket, "removed", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:directory_order, order}, socket) do
    push(socket, "directory_order", %{order: order})
    {:noreply, socket}
  end
end
