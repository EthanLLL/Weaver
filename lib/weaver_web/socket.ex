defmodule WeaverWeb.Socket do
  @moduledoc """
  A browser's connection: a token from `POST /login`, and the tenant, settled
  here once from the host it connected to; every channel on the socket is
  that tenant's.
  """
  use Phoenix.Socket

  channel("terminal", WeaverWeb.TerminalChannel)

  @impl true
  def connect(%{"token" => token}, socket, %{uri: %URI{host: host}}) do
    with :ok <- WeaverWeb.Auth.verify_token(token),
         {:ok, tenant} <- WeaverWeb.Tenant.from_host(host) do
      {:ok, assign(socket, :tenant, tenant)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
