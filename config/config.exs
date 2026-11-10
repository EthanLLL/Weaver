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

# The platform's own data, shared by every node: Aurora PostgreSQL (database
# `weaver`), reached from the hosts only. What is the tenant's (sessions,
# files, credentials) stays in their VM; what Weaver acts on while a tenant
# is not running (cron, devices, push subscriptions) is here.
config :weaver, ecto_repos: [Weaver.Repo]

config :weaver, Weaver.Repo,
  # Every node migrates at boot; the lock makes it one at a time.
  migration_lock: :pg_advisory_lock,
  migration_timestamps: [type: :utc_datetime_usec]

config :phoenix, :json_library, Jason

config :mime, :types, %{"application/manifest+json" => ["webmanifest"]}
config :logger, level: :info
