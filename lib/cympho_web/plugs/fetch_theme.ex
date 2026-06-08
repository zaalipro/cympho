defmodule CymphoWeb.Plugs.FetchTheme do
  @moduledoc """
  Reads the `theme` cookie, validates it against `Cympho.Themes`, and assigns
  `:theme` so the root layout can stamp `<html data-theme>` on the very first
  paint — before LiveView connects — avoiding a flash of the wrong theme.

  The cookie is a render hint written client-side by the `ThemeManager` JS hook
  (and seeded at login from the DB). The durable source of truth is
  `users.theme`; an unknown/absent cookie falls back to the default theme.
  """
  import Plug.Conn

  @cookie "theme"

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = fetch_cookies(conn)
    assign(conn, :theme, Cympho.Themes.normalize(conn.cookies[@cookie]))
  end
end
