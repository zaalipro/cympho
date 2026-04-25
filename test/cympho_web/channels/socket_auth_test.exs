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
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => "garbage"})
    end

    test "rejects an expired JWT token" do
      secret = Application.get_env(:cympho, :agent_jwt_secret, "default-secret-change-in-production")

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
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => token})
    end
  end

  describe "connect/3 with session" do
    test "authenticates with valid session data" do
      company_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      assert {:ok, socket} = connect_session(company_id, user_id)
      assert socket.assigns.company_id == company_id
      assert socket.assigns.user_id == user_id
      assert socket.assigns.auth_method == :session
    end

    test "rejects when session is missing" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{}, %{})
    end

    test "rejects when session has no company_id" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(
                 CymphoWeb.Socket,
                 %{},
                 %{session: %{"user_id" => Ecto.UUID.generate()}}
               )
    end

    test "rejects when session has no user_id" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(
                 CymphoWeb.Socket,
                 %{},
                 %{session: %{"company_id" => Ecto.UUID.generate()}}
               )
    end
  end

  describe "connect/3 rejects anonymous" do
    test "rejects connections with no credentials" do
      assert {:error, :unauthorized} ==
               Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{})
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
