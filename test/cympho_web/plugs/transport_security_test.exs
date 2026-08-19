defmodule CymphoWeb.Plugs.TransportSecurityTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias CymphoWeb.Plugs.TransportSecurity

  setup do
    previous = Application.get_env(:cympho, :transport_security)

    on_exit(fn ->
      if previous do
        Application.put_env(:cympho, :transport_security, previous)
      else
        Application.delete_env(:cympho, :transport_security)
      end
    end)
  end

  test "accepts forwarded HTTPS only from an explicitly trusted immediate proxy" do
    configure_transport(trusted_proxy_ips: [{127, 0, 0, 1}])

    conn =
      conn(:get, "/login")
      |> put_req_header("x-forwarded-proto", "https")
      |> TransportSecurity.call([])

    assert conn.scheme == :https
    refute conn.halted
    assert get_resp_header(conn, "strict-transport-security") == ["max-age=31536000"]
  end

  test "matches exact IPv4 and IPv6 proxy addresses" do
    configure_transport(trusted_proxy_ips: [{10, 0, 0, 8}, {0, 0, 0, 0, 0, 0, 0, 1}])

    assert TransportSecurity.trusted_peer?({10, 0, 0, 8})
    assert TransportSecurity.trusted_peer?({0, 0, 0, 0, 0, 0, 0, 1})
    refute TransportSecurity.trusted_peer?({10, 0, 0, 9})
  end

  test "matches IPv4 and IPv6 CIDRs without crossing address families" do
    configure_transport(
      trusted_proxy_ips: [
        {{10, 24, 0, 0}, 16},
        {{0x2001, 0xDB8, 0xCAFE, 0, 0, 0, 0, 0}, 48}
      ]
    )

    assert TransportSecurity.trusted_peer?({10, 24, 99, 7})
    refute TransportSecurity.trusted_peer?({10, 25, 0, 1})

    assert TransportSecurity.trusted_peer?({0x2001, 0xDB8, 0xCAFE, 1, 0, 0, 0, 1})
    refute TransportSecurity.trusted_peer?({0x2001, 0xDB8, 0xBEEF, 1, 0, 0, 0, 1})
    refute TransportSecurity.trusted_peer?({10, 24, 0, 1}, [{{0, 0, 0, 0, 0, 0, 0, 0}, 0}])
  end

  test "accepts forwarded HTTPS from a proxy inside an allowed CIDR" do
    configure_transport(trusted_proxy_ips: [{{10, 42, 0, 0}, 16}])

    conn =
      conn(:get, "/login")
      |> Map.put(:remote_ip, {10, 42, 3, 9})
      |> put_req_header("x-forwarded-proto", "https")
      |> TransportSecurity.call([])

    assert conn.scheme == :https
    refute conn.halted
  end

  test "an untrusted peer cannot spoof forwarded HTTPS or the redirect host" do
    configure_transport(trusted_proxy_ips: [{10, 0, 0, 2}])

    conn =
      conn(:get, "/login?return_to=%2Fissues")
      |> Map.put(:host, "attacker.example")
      |> put_req_header("x-forwarded-proto", "https")
      |> TransportSecurity.call([])

    assert conn.halted
    assert conn.status == 301

    assert get_resp_header(conn, "location") ==
             ["https://cympho.example/login?return_to=%2Fissues"]
  end

  test "plain HTTP from a trusted proxy still redirects to HTTPS" do
    configure_transport(trusted_proxy_ips: [{127, 0, 0, 1}])

    conn =
      conn(:post, "/login")
      |> put_req_header("x-forwarded-proto", "http")
      |> TransportSecurity.call([])

    assert conn.halted
    assert conn.status == 307
    assert get_resp_header(conn, "location") == ["https://cympho.example/login"]
  end

  test "the explicit force-SSL off switch leaves local HTTP unchanged" do
    Application.put_env(:cympho, :transport_security,
      force_ssl: false,
      host: "cympho.example",
      trusted_proxy_ips: []
    )

    conn = conn(:get, "/") |> TransportSecurity.call([])

    refute conn.halted
    assert conn.scheme == :http
    assert get_resp_header(conn, "location") == []
  end

  defp configure_transport(overrides) do
    Application.put_env(
      :cympho,
      :transport_security,
      Keyword.merge(
        [force_ssl: true, host: "cympho.example", trusted_proxy_ips: []],
        overrides
      )
    )
  end
end
