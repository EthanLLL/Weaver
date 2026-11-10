defmodule WeaverWeb.UserSocket do
  @moduledoc """
  A browser's connection: the token from `POST /api/login`, and the tenant,
  settled here once from the host it connected to. Every channel on the
  socket is that tenant's, whatever its topic says.
  """
  use Phoenix.Socket

  channel("agents", WeaverWeb.LobbyChannel)
  channel("agent:*", WeaverWeb.AgentChannel)
  channel("terminal:*", WeaverWeb.TerminalChannel)

  @impl true
  def connect(%{"token" => token}, socket, %{uri: %URI{host: host}}) do
    with {:ok, tenant} <- WeaverWeb.Tenant.from_host(host),
         :ok <- WeaverWeb.Auth.verify_token(token, tenant) do
      {:ok, assign(socket, :tenant, tenant)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
