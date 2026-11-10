defmodule WeaverWeb.Socket do
  @moduledoc """
  A browser's connection. The tenant is settled here, once, from the host it
  connected to; every channel on the socket is that tenant's.
  """
  use Phoenix.Socket

  channel("terminal", WeaverWeb.TerminalChannel)

  @impl true
  def connect(_params, socket, %{uri: %URI{host: host}}) do
    case WeaverWeb.Tenant.from_host(host) do
      {:ok, tenant} -> {:ok, assign(socket, :tenant, tenant)}
      :error -> :error
    end
  end

  @impl true
  def id(_socket), do: nil
end
