import Config

config :cympho, CymphoWeb.Endpoint,
  url: [host: System.get_env("APP_HOST") || "localhost", port: 443],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :cympho, Cympho.Repo,
  url: System.get_env("DATABASE_URL"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true,
  ssl_opts: [verify: :verify_peer],
  ssl_verify_host: true

config :cympho, CymphoWeb.Endpoint,
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT") || "cympho"],
  check_origin: ["//" <> (System.get_env("APP_HOST") || "localhost")]

# Session secret for AgentAuth plug
config :cympho, :agent_auth,
  secret_key_base: System.get_env("AGENT_AUTH_SECRET") || System.get_env("SECRET_KEY_BASE")