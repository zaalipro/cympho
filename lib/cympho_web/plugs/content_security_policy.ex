defmodule CymphoWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a Content-Security-Policy on browser responses.

  Scripts must come from this origin, the pinned SortableJS CDN, or carry the
  per-request nonce assigned as `@csp_nonce`, so injected markup cannot run
  inline scripts or event-handler attributes. Styles stay `'unsafe-inline'`
  because components use inline `style` attributes; style injection is far
  less dangerous than script injection.
  """

  @behaviour Plug

  import Plug.Conn

  # Must match the <script src> in root.html.heex.
  @sortable_js_url "https://cdn.jsdelivr.net/npm/sortablejs@1.15.6/Sortable.min.js"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    nonce = 18 |> :crypto.strong_rand_bytes() |> Base.encode64()

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy(nonce))
  end

  defp policy(nonce) do
    Enum.join(
      [
        "default-src 'self'",
        "script-src 'self' 'nonce-#{nonce}' #{@sortable_js_url}",
        "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
        "font-src 'self' data: https://fonts.gstatic.com",
        "img-src 'self' data: blob: https:",
        "connect-src 'self' #{websocket_origin()}",
        "object-src 'none'",
        "base-uri 'self'",
        "frame-ancestors 'self'"
      ],
      "; "
    )
  end

  # Older Safari releases do not treat 'self' as covering ws:/wss:, so the
  # LiveView socket origin is listed explicitly.
  defp websocket_origin do
    %URI{scheme: scheme, host: host, port: port} = CymphoWeb.Endpoint.struct_url()
    ws_scheme = if scheme == "https", do: "wss", else: "ws"

    if port in [nil, 80, 443],
      do: "#{ws_scheme}://#{host}",
      else: "#{ws_scheme}://#{host}:#{port}"
  end
end
