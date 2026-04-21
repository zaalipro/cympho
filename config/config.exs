import Config

config :cympho,
  ecto_repos: [Cympho.Repo]

config :cympho, Cympho.Repo,
  database: "cympho_repo",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

config :cympho, CymphoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CymphoWeb.ErrorHTML, json: CymphoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cympho.PubSub,
  live_view: [signing_salt: "cympho_secret"]

config :esbuild, version: "0.17.11"

config :tailwind,
  version: "3.4.0",
  cympho: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :json_library, Jason

config :swoosh, :api_client, Swoosh.ApiClient.Finch

import_config "#{config_env()}.exs"
