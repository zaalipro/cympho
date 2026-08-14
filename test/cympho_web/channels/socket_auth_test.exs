defmodule CymphoWeb.SocketAuthTest do
  use CymphoWeb.ChannelCase

  describe "connect/3 with JWT token" do
    test "authenticates with a valid JWT token" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      assert {:ok, socket} = connect_jwt(company_id, agent_id)
      assert socket.assigns.company_id == company_id
      assert socket.assigns.user_id == agent_id
      assert socket.assigns.auth_method == :jwt
    end

    test "rejects an invalid JWT token" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => "garbage"},
                 connect_info: %{}
               )
    end

    test "rejects an expired JWT token" do
      secret =
        Application.get_env(:cympho, :agent_jwt_secret, "default-secret-change-in-production")

      claims = %{
        "agent_id" => Ecto.UUID.generate(),
        "run_id" => "run-1",
        "company_id" => Ecto.UUID.generate(),
        "exp" => System.system_time(:second) - 300,
        "iat" => System.system_time(:second) - 600,
        "typ" => "agent_heartbeat"
      }

      {:ok, token} = sign_jwt(claims, secret)

      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => token},
                 connect_info: %{}
               )
    end
  end

  describe "connect/3 with session" do
    test "authenticates with valid session data" do
      {company, user} = member_user()

      assert {:ok, socket} = connect_session(company.id, user.id)
      assert socket.assigns.company_id == company.id
      assert socket.assigns.user_id == user.id
      assert socket.assigns.auth_method == :session
    end

    test "rejects a session company the user is not a member of" do
      {_company, user} = member_user()
      other = other_company()

      assert :error == connect_session(other.id, user.id)
    end

    test "rejects when session is missing" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{}, connect_info: %{})
    end

    test "rejects when session has no company_id" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(
                 CymphoWeb.Socket,
                 %{},
                 connect_info: %{session: %{"user_id" => Ecto.UUID.generate()}}
               )
    end

    test "rejects when session has no user_id" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(
                 CymphoWeb.Socket,
                 %{},
                 connect_info: %{session: %{"company_id" => Ecto.UUID.generate()}}
               )
    end
  end

  describe "extract_ip/1" do
    test "parses the first x-forwarded-for address" do
      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-forwarded-for", "203.0.113.10, 10.0.0.1"}],
               peer_data: %{address: {127, 0, 0, 1}}
             }) == {203, 0, 113, 10}
    end

    test "parses x-real-ip when x-forwarded-for is absent" do
      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-real-ip", "198.51.100.20"}],
               peer_data: %{address: {127, 0, 0, 1}}
             }) == {198, 51, 100, 20}
    end

    test "falls back to peer_data then loopback" do
      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-forwarded-for", "not-an-ip"}],
               peer_data: %{address: {10, 1, 2, 3}}
             }) == {10, 1, 2, 3}

      assert CymphoWeb.Socket.extract_ip(%{}) == {127, 0, 0, 1}
    end
  end

  describe "connect/3 rejects anonymous" do
    test "rejects connections with no credentials" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{}, connect_info: %{})
    end
  end

  describe "id/1" do
    test "returns a socket id with company and user" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      {:ok, socket} = connect_jwt(company_id, agent_id)
      assert CymphoWeb.Socket.id(socket) == "socket:#{company_id}:#{agent_id}"
    end
  end

  defp member_user do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Socket Co #{unique}",
        slug: "socket-co-#{unique}"
      })

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "socket-#{unique}@example.com",
        name: "Socket User #{unique}"
      })

    {:ok, _} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "member"
      })

    {company, user}
  end

  defp other_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Other Socket Co #{unique}",
        slug: "other-socket-co-#{unique}"
      })

    company
  end

  defp sign_jwt(claims, secret) do
    header = %{"alg" => "HS256", "typ" => "JWT"}

    encoded_header =
      header |> Jason.encode!() |> Base.encode64() |> String.replace_trailing("=", "")

    encoded_claims =
      claims |> Jason.encode!() |> Base.encode64() |> String.replace_trailing("=", "")

    signing_input = "#{encoded_header}.#{encoded_claims}"
    signature = :crypto.mac(:hmac, :sha256, secret, signing_input)
    encoded_sig = signature |> Base.encode64() |> String.replace_trailing("=", "")
    {:ok, "#{signing_input}.#{encoded_sig}"}
  end
end
