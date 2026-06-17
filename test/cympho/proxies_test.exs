defmodule Cympho.ProxiesTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Proxies
  alias Cympho.Secrets.EncryptedStorage

  describe "proxy profiles" do
    test "creates profiles from socks URLs without exposing stored credentials" do
      {:ok, company} = create_company()

      {:ok, profile} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "north-egress",
          proxy_url: "socks5://agent:secret-pass@127.0.0.1:1080",
          description: "Primary SOCKS profile"
        })

      assert profile.proxy_type == "socks5"
      assert profile.host == "127.0.0.1"
      assert profile.port == 1080
      assert profile.username == "agent"
      assert profile.description == "Primary SOCKS profile"
      assert is_binary(profile.encrypted_password)
      refute inspect(profile) =~ "secret-pass"
      assert {:ok, "secret-pass"} = EncryptedStorage.decrypt(profile.encrypted_password)

      assert [{label, id}] = Proxies.proxy_profile_options(company.id)
      assert id == profile.id
      assert label =~ "north-egress"
      assert label =~ "socks5://127.0.0.1:1080"
    end

    test "rejects profile names that look like raw proxy URLs" do
      {:ok, company} = create_company()

      assert {:error, changeset} =
               Proxies.create_proxy_profile(%{
                 company_id: company.id,
                 name: "socks5://127.0.0.1:1080",
                 proxy_type: "socks5",
                 host: "127.0.0.1",
                 port: 1080
               })

      assert %{name: [_message]} = errors_on(changeset)
    end

    test "tests TCP reachability and stores ping metadata" do
      {:ok, company} = create_company()
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listen_socket)
      parent = self()

      spawn(fn ->
        case :gen_tcp.accept(listen_socket, 3_000) do
          {:ok, socket} ->
            send(parent, :proxy_accepted)
            :gen_tcp.close(socket)

          {:error, reason} ->
            send(parent, {:proxy_accept_failed, reason})
        end

        :gen_tcp.close(listen_socket)
      end)

      {:ok, profile} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "local-test",
          proxy_type: "http",
          host: "127.0.0.1",
          port: port
        })

      assert {:ok, tested} = Proxies.test_proxy_profile(profile)
      assert_receive :proxy_accepted
      assert tested.last_status == "online"
      assert is_integer(tested.last_ping_ms)
      assert tested.last_ping_ms >= 0
      assert tested.last_checked_at
      assert tested.last_error in [nil, ""]
    end
  end

  defp create_company do
    Companies.create_company(%{
      name: "Proxy Co #{System.unique_integer([:positive])}",
      slug: "proxy-co-#{System.unique_integer([:positive])}"
    })
  end
end
