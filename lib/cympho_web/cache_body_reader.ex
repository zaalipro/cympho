defmodule CymphoWeb.CacheBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that retains the raw request body in
  `conn.assigns[:raw_body]` so webhook plugs can verify HMAC signatures over
  the bytes the client actually sent.

  Without this, by the time a verification plug runs, `Plug.Parsers` has
  already consumed the body and only the parsed `params` are available — and
  re-encoding parsed params produces different bytes than the original.
  """

  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = Plug.Conn.assign(conn, :raw_body, [body | conn.assigns[:raw_body] || []])
    {:ok, body, conn}
  end
end
