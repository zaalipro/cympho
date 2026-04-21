import Config

config :cympho, CymphoWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info

config :phoenix, :json_library, Jason
