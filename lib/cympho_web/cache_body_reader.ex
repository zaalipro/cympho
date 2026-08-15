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
    read_chunks(conn, opts, [])
  end

  # `Plug.Conn.read_body/2` returns `{:more, partial, conn}` once the body
  # exceeds the `:length` option (8MB via Plug.Parsers' default; GitHub permits
  # webhook payloads up to 25MB). Matching only `{:ok, ...}` raised a
  # MatchError inside Plug.Parsers — before `verify_signature/2` ever ran — so
  # an oversized webhook 500'd instead of being authenticated. Accumulate
  # instead, and keep the whole body so the HMAC covers the bytes sent.
  defp read_chunks(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full = IO.iodata_to_binary(Enum.reverse([body | acc]))
        {:ok, full, Plug.Conn.assign(conn, :raw_body, [full | conn.assigns[:raw_body] || []])}

      {:more, partial, conn} ->
        read_chunks(conn, opts, [partial | acc])

      {:error, reason} ->
        {:error, reason}
    end
  end
end
