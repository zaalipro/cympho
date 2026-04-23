import Config

config :cympho, CymphoWeb.Endpoint,
  url: [host: System.get_env("APP_HOST") || "localhost", port: 443],
  cache_static_manifest: "priv/static/cache_manifest.json"

if database_url = System.get_env("DATABASE_URL") do
  config :cympho, Cympho.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  if config_env() == :prod do
    config :cympho, Cympho.Repo,
      ssl: [verify: :verify_peer],
      ssl_verify_host: true
  end
end

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :cympho, CymphoWeb.Endpoint, secret_key_base: secret_key_base
end

config :cympho, CymphoWeb.Endpoint,
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT") || "cympho_live_view_signing_salt"],
  check_origin: ["//" <> (System.get_env("APP_HOST") || "localhost")]

# Session secret for AgentAuth plug
config :cympho, :agent_auth,
  secret_key_base: System.get_env("AGENT_AUTH_SECRET") || System.get_env("SECRET_KEY_BASE")
