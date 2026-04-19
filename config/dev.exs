import Config

config :cympho, Cympho.Repo,
  database: "cympho_dev",
  pool_size: 5

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

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime
