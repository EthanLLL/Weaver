defmodule WeaverWeb.BrowserController do
  @moduledoc """
  Upgrades to `WeaverWeb.VncSocket`, for the host's tenant. A browser can't
  set headers on a WebSocket, so the login token comes as `?token=`, as it
  does for `/socket`.
  """
  use WeaverWeb, :controller

  def vnc(conn, params) do
    case WeaverWeb.Auth.verify_token(params["token"]) do
      :ok ->
        # A screen that doesn't change sends nothing, and noVNC doesn't ping, so
        # the idle limit is long; a dropped connection ends it either way.
        conn
        |> WebSockAdapter.upgrade(WeaverWeb.VncSocket, conn.assigns.tenant,
          timeout: :timer.hours(4),
          compress: true
        )
        |> halt()

      {:error, _} ->
        send_resp(conn, 401, "")
    end
  end
end
