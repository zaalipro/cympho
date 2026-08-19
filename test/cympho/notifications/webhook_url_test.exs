defmodule Cympho.Notifications.WebhookURLTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Notifications.WebhookURL
  alias Cympho.Notifications.WebhookURL.Target

  describe "validate/1" do
    test "requires HTTPS with a valid host and no user information" do
      assert {:ok, %URI{host: "hooks.example"}} =
               WebhookURL.validate("https://hooks.example/events")

      invalid_urls = [
        "http://hooks.example/events",
        "ftp://hooks.example/events",
        "https:///events",
        "https://bad_host.example/events",
        "https://hooks.example/events#fragment",
        " https://hooks.example/events"
      ]

      Enum.each(invalid_urls, fn url ->
        assert WebhookURL.validate(url) == {:error, :invalid_url}
      end)

      for url <- [
            "https://user:pass@hooks.example/events",
            "https://@hooks.example/events"
          ] do
        assert WebhookURL.validate(url) == {:error, :blocked_webhook_url}
      end

      assert {:ok, %URI{host: "hooks.example"}} =
               WebhookURL.validate("https://hooks.example./events")
    end

    test "rejects IPv4 private, loopback, link-local, multicast, and reserved literals" do
      blocked_hosts = [
        "0.0.0.1",
        "10.0.0.1",
        "100.64.0.1",
        "127.0.0.1",
        "169.254.169.254",
        "172.16.0.1",
        "192.168.1.1",
        "192.0.2.1",
        "198.18.0.1",
        "198.51.100.1",
        "203.0.113.1",
        "224.0.0.1",
        "240.0.0.1",
        "255.255.255.255"
      ]

      Enum.each(blocked_hosts, fn host ->
        assert WebhookURL.validate("https://#{host}/hook") ==
                 {:error, :blocked_webhook_url}
      end)

      assert {:ok, %URI{host: "8.8.8.8"}} = WebhookURL.validate("https://8.8.8.8/hook")
    end

    test "rejects IPv6 special-use and private IPv4-mapped literals" do
      blocked_hosts = [
        "::",
        "::1",
        "::ffff:10.0.0.1",
        "::ffff:127.0.0.1",
        "64:ff9b::1",
        "2001:db8::1",
        "2002::1",
        "2620:4f:8000::1",
        "3fff::1",
        "fc00::1",
        "fd00::1",
        "fe80::1",
        "fec0::1",
        "ff02::1"
      ]

      Enum.each(blocked_hosts, fn host ->
        assert WebhookURL.validate("https://[#{host}]/hook") ==
                 {:error, :blocked_webhook_url}
      end)

      assert {:ok, %URI{host: "2606:4700:4700::1111"}} =
               WebhookURL.validate("https://[2606:4700:4700::1111]/hook")
    end
  end

  describe "resolve/2" do
    test "checks every IPv4 and IPv6 answer and pins a public address" do
      test_pid = self()

      resolver = fn "hooks.example", family ->
        send(test_pid, {:resolved, family})

        case family do
          :inet -> {:ok, [{8, 8, 8, 8}, {1, 1, 1, 1}]}
          :inet6 -> {:ok, [{0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}]}
        end
      end

      assert {:ok,
              %Target{
                address: {8, 8, 8, 8},
                addresses: [
                  {8, 8, 8, 8},
                  {1, 1, 1, 1},
                  {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
                ]
              }} = WebhookURL.resolve("https://hooks.example/hook", resolver: resolver)

      assert_receive {:resolved, :inet}
      assert_receive {:resolved, :inet6}
    end

    test "rejects the whole host when any DNS answer is non-public" do
      test_pid = self()

      resolver = fn "hooks.example", family ->
        send(test_pid, {:resolved, family})

        case family do
          :inet -> {:ok, [{8, 8, 8, 8}]}
          :inet6 -> {:ok, [{0xFD00, 0, 0, 0, 0, 0, 0, 1}]}
        end
      end

      assert WebhookURL.resolve("https://hooks.example/hook", resolver: resolver) ==
               {:error, :blocked_webhook_url}

      assert_receive {:resolved, :inet}
      assert_receive {:resolved, :inet6}
    end

    test "rejects non-canonical numeric hosts before DNS" do
      resolver = fn _host, _family -> flunk("numeric hosts must not be resolved") end

      for host <- ["2130706433", "0177.0.0.1", "0x7f.0.0.1"] do
        assert WebhookURL.resolve("https://#{host}/hook", resolver: resolver) ==
                 {:error, :blocked_webhook_url}
      end
    end

    test "fails closed on DNS errors or an empty result" do
      error_resolver = fn _host, _family -> {:error, :timeout} end
      empty_resolver = fn _host, _family -> {:error, :nxdomain} end

      assert WebhookURL.resolve("https://hooks.example/hook", resolver: error_resolver) ==
               {:error, :unresolvable_host}

      assert WebhookURL.resolve("https://hooks.example/hook", resolver: empty_resolver) ==
               {:error, :unresolvable_host}
    end
  end

  describe "post/4" do
    test "stops after the final status without consuming the response body" do
      resolver = fn
        _host, :inet -> {:ok, [{8, 8, 8, 8}]}
        _host, :inet6 -> {:error, :nxdomain}
      end

      test_pid = self()
      request_ref = make_ref()

      with_mock Mint.HTTP, [:passthrough],
        connect: fn :https, _address, _port, _opts -> {:ok, :connection} end,
        request: fn :connection, "POST", _path, _headers, "{}" ->
          {:ok, :connection, request_ref}
        end,
        recv: fn :connection, 0, timeout ->
          send(test_pid, {:recv_timeout, timeout})

          {:ok, :connection,
           [
             {:status, request_ref, 204},
             {:headers, request_ref, [{"x-ignored", :binary.copy("x", 70_000)}]},
             {:data, request_ref, :binary.copy("x", 1_000_000)}
           ]}
        end,
        close: fn :connection -> {:ok, :connection} end do
        assert WebhookURL.post("https://hooks.example/hook", [], "{}", resolver: resolver) ==
                 {:ok, 204}
      end

      assert_receive {:recv_timeout, timeout}
      assert timeout > 0 and timeout <= 15_000
    end

    test "bounds informational response headers before a final status" do
      resolver = fn
        _host, :inet -> {:ok, [{8, 8, 8, 8}]}
        _host, :inet6 -> {:error, :nxdomain}
      end

      request_ref = make_ref()

      with_mock Mint.HTTP, [:passthrough],
        connect: fn :https, _address, _port, _opts -> {:ok, :connection} end,
        request: fn :connection, "POST", _path, _headers, "{}" ->
          {:ok, :connection, request_ref}
        end,
        recv: fn :connection, 0, _timeout ->
          {:ok, :connection,
           [
             {:status, request_ref, 103},
             {:headers, request_ref, Enum.map(1..101, &{"x-hint-#{&1}", "value"})}
           ]}
        end,
        close: fn :connection -> {:ok, :connection} end do
        assert WebhookURL.post("https://hooks.example/hook", [], "{}", resolver: resolver) ==
                 {:error, :response_headers_too_large}
      end
    end

    test "connects to the pinned tuple without resolving the hostname again" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      resolver = fn "hooks.example", family ->
        call = Agent.get_and_update(counter, fn count -> {count + 1, count + 1} end)

        case {call, family} do
          {1, :inet} -> {:ok, [{8, 8, 8, 8}]}
          {2, :inet6} -> {:error, :nxdomain}
          {_later_rebind, :inet} -> {:ok, [{127, 0, 0, 1}]}
          {_later_rebind, :inet6} -> {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
        end
      end

      test_pid = self()

      with_mock Mint.HTTP, [:passthrough],
        connect: fn :https, address, port, opts ->
          send(test_pid, {:connect, address, port, opts})
          {:ok, :connection}
        end,
        request: fn :connection, "POST", path, headers, "{}" ->
          send(test_pid, {:request, path, headers})
          {:error, :connection, :request_stopped}
        end,
        close: fn :connection -> {:ok, :connection} end do
        assert WebhookURL.post("https://hooks.example/hook?event=ping", [], "{}",
                 resolver: resolver
               ) == {:error, :request_stopped}
      end

      assert Agent.get(counter, & &1) == 2

      assert_receive {:connect, {8, 8, 8, 8}, 443, opts}
      assert opts[:hostname] == "hooks.example"

      assert_receive {:request, "/hook?event=ping", headers}
      assert {"Host", "hooks.example"} in headers
    end
  end
end
