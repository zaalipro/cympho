import Config

config :cympho,
  ecto_repos: [Cympho.Repo]

config :cympho, Cympho.Repo,
  database: "cympho_repo",
  pool_size: 10,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

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

# Sentry SDK base config. DSN is loaded from SENTRY_DSN in runtime.exs and
# is `nil` by default, which makes Sentry a no-op (no events are sent).
config :sentry,
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()]

config :cympho, Cympho.Scheduler,
  jobs: [
    # Daily retention sweep at 03:17 UTC. `:overlap, false` ensures concurrent
    # runs are skipped if a previous sweep is still running.
    retention: [
      schedule: "17 3 * * *",
      task: {Cympho.Retention, :run_all, []},
      overlap: false
    ],
    # Every 5 minutes, re-emit / escalate any review nudges that have gone
    # stale. The scanner is idempotent and cheap when there are no nudges,
    # so it can run frequently without cost. Overlap-guarded so a slow
    # sweep doesn't pile up.
    review_nudge_stale_scan: [
      schedule: "*/5 * * * *",
      task: {Cympho.ReviewNudges.StaleScanner, :sweep, [[]]},
      overlap: false
    ]
  ],
  timezone: "Etc/UTC"

config :cympho, :review_nudges,
  stale_t1_seconds: 120,
  stale_t2_seconds: 600,
  max_re_emits: 3

config :swoosh, :api_client, Swoosh.ApiClient.Finch

config :cympho, Cympho.Mailer, finch_name: Cympho.Finch

config :cympho,
  uploads_dir: "priv/static/uploads",
  storage_backend: Cympho.Attachments.Storage.LocalStorage

config :cympho, Cympho.Finch,
  pools: [
    default: [
      size: 5
    ]
  ]

# Autonomy polish (spec 01) — defaults
config :cympho, :llm_router_enabled?, true
config :cympho, :llm_classifier_timeout_ms, 1_500
config :cympho, :start_execution_policy_advancer?, true

# JWT signing secrets. Dev/test use these fixed, non-secret defaults; production
# requires CYMPHO_USER_JWT_SECRET / CYMPHO_AGENT_JWT_SECRET (set in runtime.exs),
# whose absence fails the boot. There is no hardcoded production fallback.
config :cympho,
  user_jwt_secret: "dev-only-user-jwt-secret-not-for-production",
  agent_jwt_secret: "dev-only-agent-jwt-secret-not-for-production"

import_config "#{config_env()}.exs"
