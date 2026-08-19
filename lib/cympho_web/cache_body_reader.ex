defmodule CymphoWeb.CacheBodyReader do
  @moduledoc """
  Custom body reader for `Plug.Parsers` that retains the raw GitHub webhook
  body in `conn.assigns[:raw_body]` so its HMAC can be verified over the bytes
  the client actually sent.

  Without this, by the time a verification plug runs, `Plug.Parsers` has
  already consumed the body and only the parsed `params` are available — and
  re-encoding parsed params produces different bytes than the original.
  """

  @github_webhook_path "/api/github/webhook"
  @max_webhook_body_bytes 25_000_000

  def read_body(conn, opts) do
    read_body(conn, opts, @max_webhook_body_bytes)
  end

  @doc false
  def read_body(%Plug.Conn{request_path: @github_webhook_path} = conn, opts, max_body_bytes)
      when is_integer(max_body_bytes) and max_body_bytes > 0 do
    read_chunks(conn, opts, [], 0, max_body_bytes)
  end

  def read_body(conn, opts, _max_body_bytes), do: Plug.Conn.read_body(conn, opts)

  # `Plug.Conn.read_body/2` returns `{:more, partial, conn}` once the body
  # exceeds the `:length` option (8MB via Plug.Parsers' default; GitHub permits
  # webhook payloads up to 25MB). Matching only `{:ok, ...}` raised a
  # MatchError inside Plug.Parsers — before `verify_signature/2` ever ran — so
  # an oversized webhook 500'd instead of being authenticated. Accumulate
  # within that 25MB envelope, and keep the whole accepted body so the HMAC
  # covers the bytes sent. Returning `:more` at the cumulative limit lets
  # Plug.Parsers produce its normal HTTP 413 response.
  defp read_chunks(conn, opts, acc, size, max_body_bytes) do
    remaining = max_body_bytes - size
    read_opts = Keyword.put(opts, :length, min(Keyword.get(opts, :length, remaining), remaining))

    case Plug.Conn.read_body(conn, read_opts) do
      {:ok, body, conn} ->
        if size + byte_size(body) <= max_body_bytes do
          full = IO.iodata_to_binary(Enum.reverse([body | acc]))
          {:ok, full, Plug.Conn.assign(conn, :raw_body, [full | conn.assigns[:raw_body] || []])}
        else
          {:more, "", conn}
        end

      {:more, partial, conn} ->
        next_size = size + byte_size(partial)

        if next_size >= max_body_bytes do
          {:more, "", conn}
        else
          read_chunks(conn, opts, [partial | acc], next_size, max_body_bytes)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
