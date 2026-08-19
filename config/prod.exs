import Config

config :cympho, CymphoWeb.Endpoint,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Phoenix inserts this guard before socket dispatch. The exclusion callback
  # only permits HTTPS asserted by an explicitly trusted immediate proxy (or
  # an operator's deliberate CYMPHO_FORCE_SSL=false override). The endpoint's
  # TransportSecurity plug then rewrites that trusted request and adds HSTS.
  force_ssl: [
    host: {CymphoWeb.Plugs.TransportSecurity, :configured_host, []},
    exclude: [conn: {CymphoWeb.Plugs.TransportSecurity, :exclude_from_builtin_ssl?, []}]
  ]

# Releases are compiled with Secure browser cookies. The endpoint reads these
# options at compile time so LiveView/channel handshakes and Plug.Session use
# exactly the same cookie contract.
config :cympho, :session_options, secure: true

config :logger, level: :info

config :phoenix, :json_library, Jason
