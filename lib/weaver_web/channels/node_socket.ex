defmodule WeaverWeb.NodeSocket do
  @moduledoc """
  Where `weaver-node daemon` connects, apart from the browser's
  `WeaverWeb.UserSocket`: a device holds a device token, not a login, and
  must never reach a session or a terminal. Its one channel is
  `WeaverWeb.NodeChannel`. The tenant is the host it dialled, and its token
  must be one of that tenant's devices.
  """
  use Phoenix.Socket

  alias Weaver.Nodes

  channel("node", WeaverWeb.NodeChannel)

  @impl true
  def connect(%{"token" => token}, socket, %{uri: %URI{host: host}}) do
    with {:ok, t} <- WeaverWeb.Tenant.from_host(host),
         {:ok, id} <- WeaverWeb.At.at(t, Nodes, :authenticate, [token]) do
      {:ok, assign(socket, tenant: t, node_id: id)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "node_socket:#{socket.assigns.tenant}:#{socket.assigns.node_id}"
end
