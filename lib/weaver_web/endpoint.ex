defmodule WeaverWeb.Endpoint do
  @moduledoc """
  The web side of a host node. Every node runs one, and Cloudflare's tunnel
  sends each request to any of them: which tenant a request is for is its
  host, `<tenant>.<domain>`, and the tenant's VM can be on any node.
  """
  use Phoenix.Endpoint, otp_app: :weaver

  socket("/socket", WeaverWeb.Socket, websocket: [connect_info: [:uri]], longpoll: false)

  plug(Plug.Static, at: "/static", from: {:weaver, "priv/static"}, gzip: false)
  plug(WeaverWeb.Page)
end
