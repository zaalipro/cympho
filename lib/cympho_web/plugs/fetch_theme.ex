defmodule CymphoWeb.Plugs.FetchTheme do
  @moduledoc """
  Reads the `theme` cookie, normalizes it with `Cympho.Themes` (legacy palette
  ids map to their mode), and assigns `:theme` so the root layout can stamp
  `<html data-mode>` on the very first paint — before LiveView connects —
  avoiding a flash of the wrong mode.

  The cookie is a render hint written client-side by the `phx:set-theme`
  listener (and seeded at login from the DB). The durable source of truth is
  `users.theme`; an unknown/absent cookie falls back to System.
  """
  import Plug.Conn

  @cookie "theme"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    assign(conn, :theme, Cympho.Themes.normalize(conn.cookies[@cookie]))
  end
end
