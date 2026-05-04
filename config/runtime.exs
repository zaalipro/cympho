import Config

port =
  if config_env() == :prod, do: 443, else: String.to_integer(System.get_env("PORT") || "4000")

config :cympho, env: config_env()

endpoint_config = [url: [host: System.get_env("APP_HOST") || "localhost", port: port]]

endpoint_config =
  if config_env() == :prod do
    Keyword.put(endpoint_config, :cache_static_manifest, "priv/static/cache_manifest.json")
  else
    endpoint_config
  end

config :cympho, CymphoWeb.Endpoint, endpoint_config

if (database_url = System.get_env("DATABASE_URL")) && config_env() != :test do
  config :cympho, Cympho.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10")

  if config_env() == :prod do
    config :cympho, Cympho.Repo,
      ssl: [verify: :verify_peer],
      ssl_verify_host: true
  end
end

if secret_key_base = System.get_env("SECRET_KEY_BASE") do
  config :cympho, CymphoWeb.Endpoint, secret_key_base: secret_key_base
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
