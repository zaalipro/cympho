import Config

config :cympho, env: :test

config :cympho, Cympho.Repo,
  username: System.get_env("TEST_DB_USER") || "paperclip",
  password: System.get_env("TEST_DB_PASSWORD") || "paperclip",
  hostname: System.get_env("TEST_DB_HOST") || "localhost",
  database:
    System.get_env("TEST_DB_NAME") || "cympho_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10,
  template: "template0",
  ssl: false

config :cympho, CymphoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_phoenix_framework",
  server: false

config :logger, level: :warning

config :cympho, :skill_manifest_dir, "test/support/skill_manifests"

config :cympho, :orchestrator, enabled: false

config :phoenix, :plug_init_mode, :runtime

config :swoosh, :api_client, Swoosh.ApiClient.Test
