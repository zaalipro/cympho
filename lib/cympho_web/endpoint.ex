defmodule CymphoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :cympho

  @session_options Application.compile_env!(:cympho, :session_options)

  # This runs before sockets, static files, parsers, and sessions. Production
  # enables it from runtime.exs; local development and tests leave it disabled.
  plug CymphoWeb.Plugs.TransportSecurity
  plug CymphoWeb.Plugs.PreviewHost

  def session_options, do: @session_options

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: false

  socket "/socket", CymphoWeb.Socket,
    websocket: [connect_info: [:peer_data, :x_headers, session: @session_options]],
    longpoll: false

  plug Plug.Static,
    at: "/",
    from: :cympho,
    gzip: false,
    only: CymphoWeb.static_paths()

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    body_reader: {CymphoWeb.CacheBodyReader, :read_body, []}

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug CymphoWeb.Router
end
