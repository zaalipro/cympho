import Config

config :cympho, CymphoWeb.Endpoint, cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: %{level: :info, handle_sasl_reports: true}

config :phoenix, :json_library, Jason
