defmodule WeaverWeb.LobbyChannel do
  @moduledoc """
  The session list, pushed instead of polled (Loom's, for the socket's
  tenant). The topic the client joins is `agents`; what it hears is the
  tenant's lobby topic (`Weaver.Tenant.lobby_topic/1`).

  Server → client: join reply `%{sessions, nodes, apps, directory_order}`
  (no apps in Weaver), then "session", "removed", "directory_order",
  "node" and "node_removed" (`Weaver.Nodes`). Client → server: "directory_order", "search"
  (`Weaver.Search`) and "watching" (`Weaver.Push`).

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
       nodes: WeaverWeb.At.at(t, Weaver.Nodes, :list, []),
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

  # As in Loom: off the channel process, replied to by ref, and a new one
  # kills the one before it (and with it rg in the VM).
  def handle_in("search", %{"q" => q}, socket) when is_binary(q) do
    if pid = socket.assigns[:search], do: Process.exit(pid, :kill)
    ref = socket_ref(socket)
    t = socket.assigns.tenant

    pid =
      spawn(fn ->
        case Weaver.Search.content(t, q) do
          {:ok, hits} -> reply(ref, {:ok, %{hits: hits}})
          {:error, :no_rg} -> reply(ref, {:error, %{reason: "no_rg"}})
          {:error, reason} -> reply(ref, {:error, %{reason: inspect(reason)}})
        end
      end)

    {:noreply, assign(socket, :search, pid)}
  end

  def handle_in("watching", %{"endpoint" => endpoint} = params, socket)
      when is_binary(endpoint) do
    WeaverWeb.At.at(socket, Weaver.Push, :watching, [endpoint, params["session"], self()])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:agent_summary, summary}, socket) do
    push(socket, "session", summary)
    {:noreply, socket}
  end

  def handle_info({:agent_removed, id}, socket) do
    push(socket, "removed", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:node_summary, node}, socket) do
    push(socket, "node", node)
    {:noreply, socket}
  end

  def handle_info({:node_removed, id}, socket) do
    push(socket, "node_removed", %{id: id})
    {:noreply, socket}
  end

  def handle_info({:directory_order, order}, socket) do
    push(socket, "directory_order", %{order: order})
    {:noreply, socket}
  end
end
