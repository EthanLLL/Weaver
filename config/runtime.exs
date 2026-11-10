import Config

# Shared by every node (tokens minted on one are checked on another), from
# /etc/weaver/weaver.env on the hosts. Unset, nobody can log in.
config :weaver, WeaverWeb.Endpoint,
  secret_key_base:
    System.get_env("WEAVER_SECRET_KEY_BASE") || Base.encode64(:crypto.strong_rand_bytes(48))

config :weaver, password: System.get_env("WEAVER_PASSWORD", "")

# The VAPID key pair push notifications are sent with, base64url, raw: one for
# the platform, like the secret above, and never in a VM. Every subscription
# is bound to it, so it is kept, not rotated. Unset, there are none.
config :weaver, Weaver.Push,
  public: System.get_env("WEAVER_VAPID_PUBLIC"),
  private: System.get_env("WEAVER_VAPID_PRIVATE")
