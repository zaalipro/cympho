import Config

host = System.get_env("APP_HOST") || "localhost"

port =
  if config_env() == :prod, do: 443, else: String.to_integer(System.get_env("PORT") || "4329")

# Interface the HTTP listener binds to in prod. Defaults to loopback; deployments
# behind a containerized proxy (e.g. Traefik) set HTTP_BIND_IP=0.0.0.0 so the
# proxy container can reach the native app via the docker host-gateway address.
bind_ip =
  case System.get_env("HTTP_BIND_IP") do
    addr when is_binary(addr) and addr != "" ->
      {:ok, parsed} = addr |> String.to_charlist() |> :inet.parse_address()
      parsed

    _ ->
      {127, 0, 0, 1}
  end

config :cympho, env: config_env()

# Optional OTLP tracing. Dependencies are marked `runtime: false` and are
# started explicitly by Cympho only when the base endpoint is present. Keeping
# raw values here lets the setup module validate them before the SDK can start.
config :cympho, :open_telemetry,
  endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"),
  traces_endpoint: System.get_env("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"),
  protocol:
    System.get_env("OTEL_EXPORTER_OTLP_TRACES_PROTOCOL") ||
      System.get_env("OTEL_EXPORTER_OTLP_PROTOCOL") || "http_protobuf",
  service_name: System.get_env("OTEL_SERVICE_NAME") || "cympho",
  deployment_environment: System.get_env("RELEASE_ENV") || to_string(config_env())

endpoint_config = [url: [host: host, port: port]]

endpoint_config =
  if config_env() == :prod do
    # Behind a TLS-terminating reverse proxy: generate https URLs on 443 (for
    # links and wss websocket upgrades), but listen for plain HTTP on PORT
    # (default 4000). `server: true` makes `bin/cympho start` boot the web
    # server in a release.
    endpoint_config
    |> Keyword.put(:url, host: host, port: 443, scheme: "https")
    |> Keyword.put(:http,
      ip: bind_ip,
      port: String.to_integer(System.get_env("PORT") || "4000")
    )
    |> Keyword.put(:server, true)
    |> Keyword.put(:cache_static_manifest, "priv/static/cache_manifest.json")
  else
    endpoint_config
  end

config :cympho, CymphoWeb.Endpoint, endpoint_config

if (database_url = System.get_env("DATABASE_URL")) && config_env() != :test do
  # Default sized for: 3 concurrent orchestrators (each can hold a tx during
  # streaming/external HTTP) + dispatcher poll + heartbeat watchdog + health
  # checker stream + LiveView pubsub fan-out + headroom for spikes. Bump
  # POOL_SIZE explicitly when running more concurrent agents.
  config :cympho, Cympho.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "25")

  # Enable verified TLS to the database only when DATABASE_SSL=true (e.g. a
  # managed Postgres). The default deployment co-locates Postgres on loopback
  # where TLS is unnecessary, so leave it off unless explicitly requested.
  if config_env() == :prod and System.get_env("DATABASE_SSL") == "true" do
    config :cympho, Cympho.Repo,
      ssl: [verify: :verify_peer],
      ssl_verify_host: true
  end
end

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :cympho, CymphoWeb.Endpoint, secret_key_base: secret_key_base
end

encryption_key = System.get_env("CYMPHO_ENCRYPTION_KEY")

if config_env() == :prod and encryption_key in [nil, ""] do
  raise "CYMPHO_ENCRYPTION_KEY must be set in production"
end

if encryption_key not in [nil, ""] do
  config :cympho, :encryption_key, encryption_key
end

# JWT signing secrets must be provided explicitly in production — no fallback.
# System.fetch_env!/1 raises at boot if either is unset, so the release refuses
# to start rather than signing tokens with a publicly-known default.
if config_env() == :prod do
  config :cympho,
    user_jwt_secret: System.fetch_env!("CYMPHO_USER_JWT_SECRET"),
    agent_jwt_secret: System.fetch_env!("CYMPHO_AGENT_JWT_SECRET")
end

config :cympho, CymphoWeb.Endpoint,
  live_view: [signing_salt: System.get_env("LIVE_VIEW_SALT") || "cympho_live_view_signing_salt"],
  check_origin: ["//" <> (System.get_env("APP_HOST") || "localhost")]

if s3_bucket = System.get_env("S3_BUCKET") do
  config :cympho,
    storage_backend: Cympho.Attachments.Storage.S3Storage,
    s3_bucket: s3_bucket,
    s3_host: System.get_env("S3_HOST", "s3.amazonaws.com"),
    s3_scheme:
      if(System.get_env("S3_SCHEME") == "path",
        do: :path,
        else: :virtual_hosted
      )

  ex_aws_config = [
    access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
    secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
  ]

  ex_aws_config =
    if region = System.get_env("AWS_REGION") do
      Keyword.put(ex_aws_config, :region, region)
    else
      ex_aws_config
    end

  ex_aws_config =
    if s3_endpoint = System.get_env("S3_ENDPOINT") do
      Keyword.put(ex_aws_config, :s3,
        scheme: :https,
        host: s3_endpoint,
        port: 443
      )
    else
      ex_aws_config
    end

  config :ex_aws, ex_aws_config

  config :ex_aws, :s3,
    scheme: :https,
    host: System.get_env("S3_HOST", "s3.amazonaws.com"),
    port: 443
end

# Session secret for AgentAuth plug
config :cympho, :agent_auth,
  secret_key_base: System.get_env("AGENT_AUTH_SECRET") || System.get_env("SECRET_KEY_BASE")

# Sentry crash reporting. When SENTRY_DSN is unset (typical dev/test), the
# SDK silently no-ops — no network calls, no errors. Production sets the env.
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: System.get_env("RELEASE_ENV", to_string(config_env()))
end
