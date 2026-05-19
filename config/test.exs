import Config

config :cympho, env: :test

config :cympho, :encryption_key, String.duplicate("t", 32)

config :cympho, Cympho.Repo,
  username: System.get_env("TEST_DB_USER") || "paperclip",
  password: System.get_env("TEST_DB_PASSWORD") || "paperclip",
  hostname: System.get_env("TEST_DB_HOST") || "localhost",
  database:
    System.get_env("TEST_DB_NAME") || "cympho_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Bumped from 10 → 24. ExUnit's `max_cases` defaults to System.schedulers_online
  # (16 in the typical CI / dev environment), so a 10-slot pool starves even
  # without the new fire-and-forget test fixtures (which create a company + 6
  # agents + 5 issues per setup). Keep `queue_target` and `queue_interval`
  # generous so a transient burst doesn't drop sandbox checkouts.
  pool_size: 24,
  queue_target: 1_000,
  queue_interval: 5_000,
  template: "template0",
  ssl: false

config :cympho, CymphoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_framework",
  server: false

config :logger, level: :warning

config :cympho, :skill_manifest_dir, "test/support/skill_manifests"

config :cympho, :orchestrator, enabled: false

# Tests that exercise the BoardApprovalActionExecutor / HeartbeatEngine.Watchdog
# start them explicitly via `start_supervised` so they can grant Ecto sandbox
# access. Starting them from the application supervisor would let global PubSub
# events / timer ticks crash them with DBConnection.OwnershipError and
# eventually take down the whole tree (including the Repo).
config :cympho, :start_board_approval_executor?, false
config :cympho, :start_heartbeat_watchdog?, false
config :cympho, :start_health_checker?, false
config :cympho, :start_scheduler?, false
config :cympho, :schedule_routine_triggers?, false
config :cympho, :start_backlog_planner?, false
config :cympho, :start_oversight_patrol?, false

# Auto-ignition fans out assign + wake under Task.Supervisor on every
# `Issues.create_issue`. Tests create issues by the thousand and expect
# deterministic state; the autonomous loop test opts back in explicitly.
config :cympho, :auto_ignite_on_create, false

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, Swoosh.ApiClient.Test
