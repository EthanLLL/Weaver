import Config

# Shared by every node (tokens minted on one are checked on another), from
# /etc/weaver/weaver.env on the hosts.
config :weaver, WeaverWeb.Endpoint,
  secret_key_base:
    System.get_env("WEAVER_SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

# The VAPID key pair push notifications are sent with, base64url, raw: one for
# the platform, like the secret above, and never in a VM. Every subscription
# is bound to it, so it is kept, not rotated. Unset, there are none.
config :weaver, Weaver.Push,
  public: System.get_env("WEAVER_VAPID_PUBLIC"),
  private: System.get_env("WEAVER_VAPID_PRIVATE")

# Aurora insists on TLS; its certificates chain to the RDS bundle in priv/.
if url = System.get_env("WEAVER_DATABASE_URL") do
  config :weaver, Weaver.Repo,
    url: url,
    pool_size: 5,
    ssl: [
      cacertfile: Path.expand("../priv/rds/global-bundle.pem", __DIR__),
      verify: :verify_peer,
      server_name_indication: url |> URI.parse() |> Map.fetch!(:host) |> String.to_charlist(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
end
