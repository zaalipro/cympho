import Config

config :cympho, :env, :dev

config :cympho, Cympho.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "cympho_dev",
  pool_size: 5,
  ssl: false

config :cympho, CymphoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  script_name: ["/dev"],
  secret_key_base: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_framework",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:cympho, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:cympho, ~w(--watch)]}
  ]

config :cympho, dev_routes: true

config :cympho,
       :encryption_key,
       System.get_env("CYMPHO_ENCRYPTION_KEY") || String.duplicate("d", 32)

config :logger, :console, format: "[$level] $message\n"

config :cympho, :skill_manifest_dir, "priv/skill_manifests"

config :cympho, :claude_code_command, System.get_env("CYMPHO_CLAUDE_COMMAND") || "cz"

config :cympho, :orchestrator,
  enabled: System.get_env("CYMPHO_ORCHESTRATOR_ENABLED") in ["1", "true", "TRUE", "yes"]

config :cympho,
       :start_board_approval_executor?,
       System.get_env("CYMPHO_START_BOARD_APPROVAL_EXECUTOR") in ["1", "true", "TRUE", "yes"]

config :cympho,
       :start_heartbeat_watchdog?,
       System.get_env("CYMPHO_START_HEARTBEAT_WATCHDOG") in ["1", "true", "TRUE", "yes"]

config :cympho,
       :start_health_checker?,
       System.get_env("CYMPHO_START_HEALTH_CHECKER") in ["1", "true", "TRUE", "yes"]

config :cympho,
       :start_scheduler?,
       System.get_env("CYMPHO_START_SCHEDULER") in ["1", "true", "TRUE", "yes"]

config :cympho,
       :schedule_routine_triggers?,
       System.get_env("CYMPHO_SCHEDULE_ROUTINE_TRIGGERS") in ["1", "true", "TRUE", "yes"]

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
