defmodule Cympho.Adapters.ProviderProxyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Mock

  alias Cympho.Adapters.ProviderProxy

  @fake_upstream_base_url "https://provider.invalid/compatible/v1"
  @fake_upstream_key "fake-provider-credential"

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:inets)
    :ok
  end

  test "starts on loopback and streams an authorized Responses request with sanitized headers" do
    test_pid = self()
    request_body = ~s({"model":"fake-model","input":"private-test-prompt"})

    with_mock Finch, [:passthrough],
      build: fn method, url, headers, body ->
        send(test_pid, {:upstream_request, method, url, headers, body})
        :provider_request
      end,
      stream_while: fn :provider_request, Cympho.Finch, initial, callback, options ->
        send(test_pid, {:stream_options, options})

        events = [
          {:status, 200},
          {:headers,
           [
             {"content-type", "text/event-stream"},
             {"connection", "x-remove"},
             {"x-remove", "must-not-reach-the-client"},
             {"content-length", "9999"}
           ]},
          {:data, "data: first\n\n"},
          {:data, "data: second\n\n"}
        ]

        {:ok, run_stream(events, initial, callback)}
      end do
      proxy = start_proxy!()

      try do
        assert String.match?(ProviderProxy.base_url(proxy), ~r|^http://127\.0\.0\.1:\d+/v1$|)
        assert byte_size(ProviderProxy.capability(proxy)) >= 40
        refute inspect(proxy) =~ ProviderProxy.capability(proxy)

        log =
          capture_log(fn ->
            result =
              request(proxy, :post, "/v1/responses", request_body, [
                {"authorization", "Bearer " <> ProviderProxy.capability(proxy)},
                {"connection", "x-request-drop"},
                {"proxy-connection", "keep-alive"},
                {"x-request-drop", "must-not-reach-the-provider"},
                {"x-client-metadata", "safe-metadata"}
              ])

            send(test_pid, {:loopback_result, result})
          end)

        assert_receive {:loopback_result, {:ok, 200, response_headers, response_body}}
        assert response_body == "data: first\n\ndata: second\n\n"
        assert header(response_headers, "content-type") == "text/event-stream"
        assert header(response_headers, "x-remove") == nil

        assert_receive {:upstream_request, :post,
                        "https://provider.invalid/compatible/v1/responses", upstream_headers,
                        ^request_body}

        assert header(upstream_headers, "authorization") == "Bearer #{@fake_upstream_key}"
        assert header(upstream_headers, "x-client-metadata") == "safe-metadata"
        assert header(upstream_headers, "x-request-drop") == nil
        assert header(upstream_headers, "proxy-connection") == nil

        refute Enum.any?(upstream_headers, fn {_name, value} ->
                 String.contains?(value, ProviderProxy.capability(proxy))
               end)

        assert_receive {:stream_options, options}
        assert options[:pool_timeout] == 5_000
        assert options[:receive_timeout] == 30_000
        assert options[:request_timeout] == 120_000

        refute log =~ @fake_upstream_key
        refute log =~ ProviderProxy.capability(proxy)
        refute log =~ "private-test-prompt"
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "rejects missing capabilities, other methods, paths, and query strings without forwarding" do
    test_pid = self()

    with_mock Finch, [:passthrough],
      build: fn method, url, headers, body ->
        send(test_pid, {:unexpected_forward, method, url, headers, body})
        :provider_request
      end do
      proxy = start_proxy!()

      try do
        assert {:ok, 401, _headers, "unauthorized"} =
                 request(proxy, :post, "/v1/responses", "{}")

        assert {:ok, 401, _headers, "unauthorized"} =
                 request(proxy, :post, "/v1/responses", "{}", [
                   {"authorization", "Bearer wrong-capability"}
                 ])

        assert {:ok, 405, headers, "method not allowed"} =
                 request(proxy, :get, "/v1/responses", "", authorized_headers(proxy))

        assert header(headers, "allow") == "POST"

        assert {:ok, 404, _headers, "not found"} =
                 request(proxy, :post, "/v1/other", "{}", authorized_headers(proxy))

        assert {:ok, 404, _headers, "not found"} =
                 request(
                   proxy,
                   :post,
                   "/v1/responses?debug=true",
                   "{}",
                   authorized_headers(proxy)
                 )

        refute_receive {:unexpected_forward, _, _, _, _}
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "enforces request and response body limits" do
    test_pid = self()

    with_mock Finch, [:passthrough],
      build: fn _method, _url, _headers, body ->
        send(test_pid, {:forwarded_body, body})
        :provider_request
      end,
      stream_while: fn :provider_request, Cympho.Finch, initial, callback, _options ->
        events = [{:status, 200}, {:headers, []}, {:data, "12345"}]
        {:ok, run_stream(events, initial, callback)}
      end do
      proxy = start_proxy!(max_request_bytes: 4, max_response_bytes: 4)

      try do
        assert {:ok, 413, _headers, "request body too large"} =
                 request(proxy, :post, "/v1/responses", "12345", authorized_headers(proxy))

        refute_receive {:forwarded_body, _}

        assert {:ok, 502, _headers, "provider response too large"} =
                 request(proxy, :post, "/v1/responses", "1234", authorized_headers(proxy))

        assert_receive {:forwarded_body, "1234"}
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "applies one wall-clock deadline to the complete inbound body" do
    test_pid = self()

    with_mock Finch, [:passthrough],
      build: fn method, url, headers, body ->
        send(test_pid, {:unexpected_forward, method, url, headers, body})
        :provider_request
      end do
      proxy = start_proxy!(read_timeout_ms: 75)
      uri = URI.parse(ProviderProxy.base_url(proxy))

      try do
        assert {:ok, socket} =
                 :gen_tcp.connect({127, 0, 0, 1}, uri.port, [:binary, active: false], 1_000)

        request_head = [
          "POST /v1/responses HTTP/1.1\r\n",
          "Host: 127.0.0.1\r\n",
          "Authorization: Bearer ",
          ProviderProxy.capability(proxy),
          "\r\nContent-Type: application/json\r\n",
          "Content-Length: 3\r\n",
          "Connection: close\r\n\r\n",
          "1"
        ]

        assert :ok = :gen_tcp.send(socket, request_head)
        Process.sleep(100)
        assert {:ok, response} = :gen_tcp.recv(socket, 0, 1_000)
        assert response =~ " 408 "
        refute_receive {:unexpected_forward, _, _, _, _}
        :gen_tcp.close(socket)
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "aborts the downstream stream when a later response chunk crosses the limit" do
    with_mock Finch, [:passthrough],
      build: fn _method, _url, _headers, _body -> :provider_request end,
      stream_while: fn :provider_request, Cympho.Finch, initial, callback, _options ->
        events = [{:status, 200}, {:headers, []}, {:data, "1234"}, {:data, "5"}]
        {:ok, run_stream(events, initial, callback)}
      end do
      proxy = start_proxy!(max_response_bytes: 4)

      try do
        result = request(proxy, :post, "/v1/responses", "{}", authorized_headers(proxy))
        refute match?({:ok, 200, _headers, "1234"}, result)
        assert {:error, _reason} = result
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "maps an upstream receive timeout to a bounded generic error" do
    with_mock Finch, [:passthrough],
      build: fn _method, _url, _headers, _body -> :provider_request end,
      stream_while: fn :provider_request, Cympho.Finch, initial, _callback, _options ->
        {:error, %Mint.TransportError{reason: :timeout}, initial}
      end do
      proxy = start_proxy!()

      try do
        assert {:ok, 504, _headers, "provider request timeout"} =
                 request(proxy, :post, "/v1/responses", "{}", authorized_headers(proxy))
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "rejects an upstream redirect without exposing its location" do
    test_pid = self()

    with_mock Finch, [:passthrough],
      build: fn method, url, headers, body ->
        send(test_pid, {:built_request, method, url, headers, body})
        :provider_request
      end,
      stream_while: fn :provider_request, Cympho.Finch, initial, callback, _options ->
        events = [
          {:status, 307},
          {:headers, [{"location", "https://redirect.invalid/v1/responses"}]}
        ]

        {:ok, run_stream(events, initial, callback)}
      end do
      proxy = start_proxy!()

      try do
        assert {:ok, 502, headers, "provider redirect rejected"} =
                 request(proxy, :post, "/v1/responses", "{}", authorized_headers(proxy))

        assert header(headers, "location") == nil

        assert_receive {:built_request, :post, "https://provider.invalid/compatible/v1/responses",
                        _, "{}"}

        refute_receive {:built_request, _, "https://redirect.invalid/v1/responses", _, _}
      after
        assert :ok = ProviderProxy.stop(proxy)
      end
    end
  end

  test "validates the fixed HTTPS upstream and all configurable safety bounds" do
    assert {:error, {:missing_option, :upstream_base_url}} = ProviderProxy.start([])

    for invalid_url <- [
          "http://provider.invalid/v1",
          "https://user:password@provider.invalid/v1",
          "https://provider.invalid/v1?target=other",
          "https://provider.invalid/v1#fragment",
          "https://provider.invalid/v1/../other",
          "https://provider.invalid/v1//other",
          "https://provider.invalid:bad/v1",
          "https://provider.invalid%2fevil/v1"
        ] do
      assert {:error, {:invalid_option, :upstream_base_url}} =
               ProviderProxy.start(
                 upstream_base_url: invalid_url,
                 api_key: @fake_upstream_key
               )
    end

    for {key, value} <- [
          {:api_key, "\n"},
          {:max_request_bytes, 0},
          {:max_request_bytes, 33 * 1_024 * 1_024},
          {:max_response_bytes, 129 * 1_024 * 1_024},
          {:timeout_ms, 0},
          {:timeout_ms, 600_001},
          {:receive_timeout_ms, :infinity},
          {:read_timeout_ms, -1}
        ] do
      options =
        [upstream_base_url: @fake_upstream_base_url, api_key: @fake_upstream_key]
        |> Keyword.put(key, value)

      assert {:error, {:invalid_option, ^key}} = ProviderProxy.start(options)
    end
  end

  test "stop is idempotent and closes the listener" do
    proxy = start_proxy!()
    assert :ok = ProviderProxy.stop(proxy)
    assert :ok = ProviderProxy.stop(proxy)

    assert {:error, _reason} =
             request(proxy, :post, "/v1/responses", "{}", authorized_headers(proxy))
  end

  defp start_proxy!(overrides \\ []) do
    options =
      [upstream_base_url: @fake_upstream_base_url, api_key: @fake_upstream_key]
      |> Keyword.merge(overrides)

    assert {:ok, proxy} = ProviderProxy.start(options)
    proxy
  end

  defp authorized_headers(proxy) do
    [{"authorization", "Bearer " <> ProviderProxy.capability(proxy)}]
  end

  defp request(proxy, method, path, body, headers \\ []) do
    url =
      proxy
      |> ProviderProxy.base_url()
      |> String.replace_suffix("/v1", path)
      |> String.to_charlist()

    request_headers =
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end)

    request =
      if method in [:post, :put, :patch] do
        {url, request_headers, ~c"application/json", body}
      else
        {url, request_headers}
      end

    case :httpc.request(
           method,
           request,
           [timeout: 2_000, connect_timeout: 1_000, autoredirect: false],
           body_format: :binary
         ) do
      {:ok, {{_http_version, status, _reason_phrase}, response_headers, response_body}} ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_stream(events, initial, callback) do
    Enum.reduce_while(events, initial, fn event, accumulator ->
      case callback.(event, accumulator) do
        {:cont, accumulator} -> {:cont, accumulator}
        {:halt, accumulator} -> {:halt, accumulator}
      end
    end)
  end

  defp header(headers, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if name |> to_string() |> String.downcase() == expected_name do
        to_string(value)
      end
    end)
  end
end
