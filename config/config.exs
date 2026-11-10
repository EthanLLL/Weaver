import Config

# Behind cloudflared on the same host, so loopback only. Origins are the
# tenants' own hosts, <tenant>.<domain>.
config :weaver, WeaverWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  server: true,
  pubsub_server: Weaver.PubSub,
  check_origin: ["//*.luozhen.cloud"]

config :weaver, domain: "luozhen.cloud"

config :phoenix, :json_library, Jason

config :mime, :types, %{"application/manifest+json" => ["webmanifest"]}
config :logger, level: :info
