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

config :esbuild,
  version: "0.17.11",
  cympho: [
    args:
      ~w(js/app.js --bundle --target=es2016 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

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

config :cympho, Cympho.Scheduler,
  jobs: [],
  timezone: "Etc/UTC"

config :swoosh, :api_client, Swoosh.ApiClient.Finch

config :cympho, Cympho.Mailer,
  finch_name: Cympho.Finch

config :cympho, Cympho.Finch,
  pools: [
    default: [
      size: 5
    ]
  ]

import_config "#{config_env()}.exs"
