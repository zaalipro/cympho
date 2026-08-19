defmodule CymphoWeb.CacheBodyReaderTest do
  use ExUnit.Case, async: true

  alias CymphoWeb.CacheBodyReader

  # Plug.Conn.read_body/2 returns {:more, partial, conn} once the body exceeds
  # the :length option — 8MB via Plug.Parsers' default, and GitHub allows
  # webhook payloads up to 25MB. The reader must accumulate rather than crash:
  # the failure lands inside Plug.Parsers, before verify_signature/2 runs, so a
  # broken reader means the HMAC check never executes at all.
  #
  # The tests force a tiny :length so the chunked path is exercised cheaply.
  defp conn_with_body(body, read_opts, path \\ "/api/github/webhook") do
    Plug.Test.conn(:post, path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> CacheBodyReader.read_body(read_opts)
  end

  defp raw_binary(conn) do
    conn.assigns[:raw_body] |> IO.iodata_to_binary()
  end

  describe "read_body/2" do
    test "reads a small body in one pass" do
      body = ~s({"zen":"Keep it logically awesome."})
      assert {:ok, read, conn} = conn_with_body(body, [])
      assert read == body
      assert raw_binary(conn) == body
    end

    test "accumulates a body delivered in multiple chunks" do
      # 300KB of JSON, forced through a tiny read window so read_body/2 must
      # return {:more, ...} many times.
      payload = ~s({"commits":") <> String.duplicate("a", 300_000) <> ~s("})
      assert {:ok, read, conn} = conn_with_body(payload, length: 1_024)
      assert byte_size(read) == byte_size(payload)
      assert read == payload
      assert raw_binary(conn) == payload
    end

    test "the accumulated body verifies an HMAC over the original bytes" do
      secret = "webhook-secret"
      payload = ~s({"ref":"refs/heads/main","data":") <> String.duplicate("z", 200_000) <> ~s("})
      expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      assert {:ok, _read, conn} = conn_with_body(payload, length: 2_048)

      actual =
        :crypto.mac(:hmac, :sha256, secret, raw_binary(conn)) |> Base.encode16(case: :lower)

      assert actual == expected
    end

    test "handles an empty body" do
      assert {:ok, "", conn} = conn_with_body("", [])
      assert raw_binary(conn) == ""
    end

    test "does not retain or accumulate bodies on unrelated routes" do
      body = String.duplicate("x", 2_048)

      assert {:more, chunk, conn} = conn_with_body(body, [length: 1_024], "/api/login")
      assert byte_size(chunk) == 1_024
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "stops once the cumulative webhook body limit is exceeded" do
      body = String.duplicate("x", 4_097)

      conn =
        Plug.Test.conn(:post, "/api/github/webhook", body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      assert {:more, "", conn} = CacheBodyReader.read_body(conn, [length: 1_024], 4_096)
      refute Map.has_key?(conn.assigns, :raw_body)
    end

    test "the cumulative limit becomes an HTTP 413 parser error" do
      conn =
        Plug.Test.conn(
          :post,
          "/api/github/webhook",
          ~s({"data":"#{String.duplicate("x", 4_096)}"})
        )
        |> Plug.Conn.put_req_header("content-type", "application/json")

      opts =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          length: 1_024,
          body_reader: {CacheBodyReader, :read_body, [4_096]}
        )

      error =
        assert_raise Plug.Parsers.RequestTooLargeError, fn ->
          Plug.Parsers.call(conn, opts)
        end

      assert error.plug_status == 413
    end
  end
end
