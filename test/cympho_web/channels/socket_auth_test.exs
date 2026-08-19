defmodule CymphoWeb.SocketAuthTest do
  use CymphoWeb.ChannelCase

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Repo

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

  describe "connect/3 with JWT token" do
    test "authenticates with a valid JWT token" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()

      assert {:ok, socket} = connect_jwt(company_id, agent_id)
      assert socket.assigns.company_id == company_id
      assert socket.assigns.user_id == agent_id
      assert is_binary(socket.assigns.run_id)
      assert socket.assigns.auth_method == :jwt
    end

    test "rejects a validly signed token when the claimed entities do not exist" do
      token = token_for(Ecto.UUID.generate(), Ecto.UUID.generate(), Ecto.UUID.generate())

      assert {:error, :unauthorized} == connect_token(token)
    end

    test "rejects terminal and mismatched run claims" do
      %{agent: agent, company: company, run: run} = socket_principal()
      other_agent = insert_agent(company)
      other_company = insert_company()

      terminal =
        Repo.insert!(%Run{
          company_id: company.id,
          agent_id: agent.id,
          issue_id: run.issue_id,
          status: "completed",
          adapter: "process",
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      invalid_tokens = [
        token_for(agent.id, terminal.id, company.id),
        token_for(other_agent.id, run.id, company.id),
        token_for(agent.id, run.id, other_company.id)
      ]

      Enum.each(invalid_tokens, fn token ->
        assert {:error, :unauthorized} == connect_token(token)
      end)
    end

    test "rejects paused, pending-approval, and terminated agents" do
      %{agent: agent, company: company, run: run} = socket_principal()
      token = token_for(agent.id, run.id, company.id)

      blocked_states = [
        %{status: :paused, governance_status: "active"},
        %{status: :pending_approval, governance_status: "active"},
        %{status: :terminated, governance_status: "active"},
        %{status: :idle, governance_status: "paused"},
        %{status: :idle, governance_status: "pending_approval"},
        %{status: :idle, governance_status: "terminated"}
      ]

      Enum.each(blocked_states, fn attrs ->
        {:ok, _updated} =
          agent
          |> Ecto.Changeset.change(attrs)
          |> Repo.update()

        assert {:error, :unauthorized} == connect_token(token)
      end)
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

    test "rejects a browser session after its server-side version is revoked" do
      {company, user} = member_user()

      assert {:ok, _socket} = connect_session(company.id, user.id, 0)
      assert {:ok, _user} = Cympho.Users.revoke_sessions(user)
      assert :error == connect_session(company.id, user.id, 0)
      assert {:ok, _socket} = connect_session(company.id, user.id, 1)
    end
  end

  describe "extract_ip/1" do
    test "parses the first x-forwarded-for address from an exact trusted proxy" do
      configure_transport(trusted_proxy_ips: [{127, 0, 0, 1}])

      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-forwarded-for", "203.0.113.10, 10.0.0.1"}],
               peer_data: %{address: {127, 0, 0, 1}}
             }) == {203, 0, 113, 10}
    end

    test "parses x-real-ip from a proxy inside a trusted CIDR" do
      configure_transport(trusted_proxy_ips: [{{10, 50, 0, 0}, 16}])

      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-real-ip", "198.51.100.20"}],
               peer_data: %{address: {10, 50, 4, 2}}
             }) == {198, 51, 100, 20}
    end

    test "ignores forwarded client addresses from an untrusted peer" do
      configure_transport(trusted_proxy_ips: [{127, 0, 0, 1}])

      assert CymphoWeb.Socket.extract_ip(%{
               x_headers: [{"x-forwarded-for", "203.0.113.10"}],
               peer_data: %{address: {10, 1, 2, 3}}
             }) == {10, 1, 2, 3}
    end

    test "falls back to peer_data then loopback" do
      configure_transport(trusted_proxy_ips: [{10, 1, 2, 3}])

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

  defp socket_principal do
    company = insert_company()
    agent = insert_agent(company)

    issue =
      Repo.insert!(%Issue{
        company_id: company.id,
        assignee_id: agent.id,
        title: "Socket auth run",
        description: "Socket auth run",
        status: :in_progress
      })

    run =
      Repo.insert!(%Run{
        company_id: company.id,
        agent_id: agent.id,
        issue_id: issue.id,
        status: "running",
        adapter: "process",
        workspace_path: System.tmp_dir!(),
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{agent: agent, company: company, run: run}
  end

  defp insert_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Socket Auth #{unique}",
        slug: "socket-auth-#{unique}"
      })

    company
  end

  defp insert_agent(company) do
    unique = System.unique_integer([:positive])

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Socket Agent #{unique}",
        role: :engineer,
        status: :running
      })

    agent
  end

  defp token_for(agent_id, run_id, company_id) do
    {:ok, token} = Cympho.AgentAuthJWT.generate_token(agent_id, run_id, company_id)
    token
  end

  defp connect_token(token) do
    Phoenix.ChannelTest.connect(CymphoWeb.Socket, %{"token" => token}, connect_info: %{})
  end

  defp configure_transport(overrides) do
    Application.put_env(
      :cympho,
      :transport_security,
      Keyword.merge(
        [force_ssl: false, host: "cympho.example", trusted_proxy_ips: []],
        overrides
      )
    )
  end
end
