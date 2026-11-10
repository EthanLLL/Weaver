defmodule WeaverWeb.Endpoint do
  @moduledoc """
  The web side of a host node. Every node runs one, and Cloudflare's tunnel
  sends each request to any of them: which tenant a request is for is its
  host, `<tenant>.<domain>` (`WeaverWeb.Plugs.Tenant`), and the tenant's VM
  can be on any node.

  The frontend is Loom's, built into `priv/static`.
  """
  use Phoenix.Endpoint, otp_app: :weaver

  socket("/socket", WeaverWeb.UserSocket,
    websocket: [connect_info: [:uri], compress: true],
    longpoll: false
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:weaver, "priv/static/assets"},
    gzip: false,
    cache_control_for_etags: "public, max-age=31536000, immutable"
  )

  plug(Plug.Static,
    at: "/vendor",
    from: {:weaver, "priv/static/vendor"},
    gzip: false,
    cache_control_for_etags: "public, max-age=86400",
    headers: %{"access-control-allow-origin" => "*"}
  )

  plug(Plug.Static,
    at: "/",
    from: :weaver,
    gzip: false,
    cache_control_for_etags: "public, max-age=86400",
    only: ~w(fonts icons favicon.ico favicon.svg icons.svg manifest.webmanifest robots.txt)
  )

  plug(Plug.Static, at: "/", from: :weaver, gzip: false, only: ~w(sw.js index.html))

  plug(WeaverWeb.Plugs.Tenant)

  plug(Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: 120_000_000}, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(WeaverWeb.Router)
end
