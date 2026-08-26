import Config

host = System.get_env("APP_HOST") || "localhost"

positive_env = fn name, default ->
  case System.get_env(name) do
    value when value in [nil, ""] ->
      default

    value ->
      case Integer.parse(value) do
        {parsed, ""} when parsed > 0 -> parsed
        _ -> raise "#{name} must be a positive integer"
      end
  end
end

# One named instance profile keeps a small VPS safe without asking operators to
# discover and tune three independent concurrency/pool knobs. Every individual
# knob remains overridable for measured deployments.
resource_profile =
  System.get_env("CYMPHO_RESOURCE_PROFILE", "balanced")
  |> String.trim()
  |> String.downcase()
  |> case do
    profile when profile in ["low", "balanced", "throughput"] -> profile
    _ -> raise "CYMPHO_RESOURCE_PROFILE must be low, balanced, or throughput"
  end

resource_defaults =
  case resource_profile do
    "low" -> %{repo_pool: 5, finch_pool: 2, max_agents: 1}
    "balanced" -> %{repo_pool: 10, finch_pool: 5, max_agents: 3}
    "throughput" -> %{repo_pool: 25, finch_pool: 10, max_agents: nil}
  end

max_concurrent_agents =
  positive_env.("CYMPHO_MAX_CONCURRENT_AGENTS", resource_defaults.max_agents)

config :cympho, resource_profile: resource_profile

if max_concurrent_agents do
  config :cympho, :orchestrator, max_concurrent_agents: max_concurrent_agents
end

config :cympho, Cympho.Finch,
  pools: [
    default: [size: positive_env.("CYMPHO_FINCH_POOL_SIZE", resource_defaults.finch_pool)]
  ]

preview_host =
  case System.get_env("PREVIEW_HOST") do
    value when value in [nil, ""] ->
      if config_env() in [:dev, :test] do
        "preview.localhost"
      else
        raise "PREVIEW_HOST must be set in production to a hostname separate from APP_HOST"
      end

    value ->
      value = value |> String.trim() |> String.downcase() |> String.trim_trailing(".")

      valid_hostname? =
        Regex.match?(
          ~r/\A(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/,
          value
        )

      unless valid_hostname? do
        raise "PREVIEW_HOST must be a hostname without a scheme, port, or path"
      end

      value
  end

if String.downcase(String.trim_trailing(host, ".")) == preview_host do
  raise "PREVIEW_HOST must use a different origin from APP_HOST"
end

config :cympho,
  preview_host: preview_host,
  preview_token_max_age: String.to_integer(System.get_env("PREVIEW_TOKEN_MAX_AGE") || "300")

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

if config_env() == :prod do
  bootstrap_secret =
    case System.get_env("CYMPHO_BOOTSTRAP_SECRET") do
      value when value in [nil, ""] ->
        nil

      value when byte_size(value) >= 32 ->
        value

      _value ->
        raise "CYMPHO_BOOTSTRAP_SECRET must be at least 32 bytes when set"
    end

  # A missing secret is intentionally allowed at boot, but leaves first-run
  # /setup unavailable. Existing configured instances do not need this secret.
  config :cympho, :bootstrap_protection, required: true, secret: bootstrap_secret

  force_ssl =
    case System.get_env("CYMPHO_FORCE_SSL") do
      value when value in [nil, "", "1", "true", "TRUE", "yes", "YES"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO"] -> false
      _value -> raise "CYMPHO_FORCE_SSL must be a boolean value"
    end

  trusted_proxy_ips =
    System.get_env("CYMPHO_TRUSTED_PROXY_IPS", "")
    |> String.split(",", trim: true)
    |> Enum.map(fn value ->
      value = String.trim(value)

      case String.split(value, "/", parts: 2) do
        [address] ->
          case :inet.parse_address(String.to_charlist(address)) do
            {:ok, ip} ->
              ip

            {:error, _reason} ->
              raise "invalid IP in CYMPHO_TRUSTED_PROXY_IPS: #{inspect(value)}"
          end

        [address, prefix_string] ->
          with {:ok, ip} <- :inet.parse_address(String.to_charlist(address)),
               {prefix, ""} <- Integer.parse(prefix_string),
               max_prefix <- if(tuple_size(ip) == 4, do: 32, else: 128),
               true <- prefix in 0..max_prefix do
            {ip, prefix}
          else
            _ -> raise "invalid CIDR in CYMPHO_TRUSTED_PROXY_IPS: #{inspect(value)}"
          end
      end
    end)

  config :cympho, :transport_security,
    force_ssl: force_ssl,
    host: host,
    trusted_proxy_ips: trusted_proxy_ips
end

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
  # The named resource profile supplies a safe default. POOL_SIZE remains an
  # explicit escape hatch after operators measure checkout latency and DB load.
  config :cympho, Cympho.Repo,
    url: database_url,
    pool_size: positive_env.("POOL_SIZE", resource_defaults.repo_pool)

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

if uploads_dir = System.get_env("CYMPHO_UPLOADS_DIR") do
  config :cympho, uploads_dir: uploads_dir
end

import_spool_dir = System.get_env("CYMPHO_IMPORT_SPOOL_DIR")

if config_env() == :prod and import_spool_dir in [nil, ""] do
  raise "CYMPHO_IMPORT_SPOOL_DIR must be set to an absolute persistent directory in production"
end

if import_spool_dir not in [nil, ""] do
  import_spool_dir = String.trim(import_spool_dir)

  if config_env() == :prod and Path.type(import_spool_dir) != :absolute do
    raise "CYMPHO_IMPORT_SPOOL_DIR must be an absolute path in production"
  end

  expanded_import_spool_dir = Path.expand(import_spool_dir)
  import_spool_components = Path.split(expanded_import_spool_dir)

  unsafe_import_spool_root? =
    Enum.any?([System.tmp_dir!(), "/tmp", "/var/tmp", "/run", "/dev/shm"], fn root ->
      root = Path.expand(root)

      expanded_import_spool_dir == root or
        String.starts_with?(expanded_import_spool_dir, root <> "/")
    end)

  unsafe_import_spool_payload? =
    Enum.any?(["_build", "releases", "current"], &(&1 in import_spool_components)) or
      String.contains?(expanded_import_spool_dir, "/priv/static/")

  if config_env() == :prod and
       (unsafe_import_spool_root? or unsafe_import_spool_payload?) do
    raise "CYMPHO_IMPORT_SPOOL_DIR must stay outside temporary and release payload paths"
  end

  config :cympho, company_import_transfer_spool_root: expanded_import_spool_dir
end

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

# BEAM introspection dashboard at /beam. This is a node-wide operator surface
# that crosses every tenant, so it is not gated by company role — it needs its
# own credentials. Both must be set or the route returns 404, which is the
# default for any install that does not opt in.
dashboard_user = System.get_env("CYMPHO_DASHBOARD_USER")
dashboard_password = System.get_env("CYMPHO_DASHBOARD_PASSWORD")

if dashboard_user && dashboard_password do
  config :cympho, :beam_dashboard, username: dashboard_user, password: dashboard_password
end

# Sentry crash reporting. When SENTRY_DSN is unset (typical dev/test), the
# SDK silently no-ops — no network calls, no errors. Production sets the env.
if sentry_dsn = System.get_env("SENTRY_DSN") do
  config :sentry,
    dsn: sentry_dsn,
    environment_name: System.get_env("RELEASE_ENV", to_string(config_env()))
end
