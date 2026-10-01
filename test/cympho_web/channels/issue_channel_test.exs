defmodule CymphoWeb.IssueChannelTest do
  use CymphoWeb.ChannelCase

  alias Cympho.{Companies, Issues, Users}

  describe "join company:<id>:issue:<id> with agent socket" do
    test "joins successfully when issue exists and belongs to socket company" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Channel test issue",
          company_id: company_id
        })

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:issue:#{issue.id}"
               )
    end

    test "rejects when issue belongs to a foreign company" do
      company_a_id = Ecto.UUID.generate()
      agent_a_id = Ecto.UUID.generate()
      {:ok, socket_a} = connect_jwt(company_a_id, agent_a_id)

      unique = System.unique_integer([:positive])

      {:ok, company_b} =
        Companies.create_company(%{name: "Company B #{unique}", slug: "co-b-#{unique}"})

      {:ok, foreign_issue} =
        Issues.create_issue(%{
          title: "Foreign issue",
          company_id: company_b.id
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_a,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a_id}:issue:#{foreign_issue.id}"
               )
    end

    test "rejects when issue does not exist" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)
      nonexistent_id = Ecto.UUID.generate()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:issue:#{nonexistent_id}"
               )
    end

    test "rejects when issue ID is not a valid UUID" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:issue:not-a-uuid"
               )
    end

    test "rejects when company_id does not match socket" do
      company_a_id = Ecto.UUID.generate()
      company_b_id = Ecto.UUID.generate()
      agent_a_id = Ecto.UUID.generate()
      {:ok, socket_a} = connect_jwt(company_a_id, agent_a_id)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Issue A",
          company_id: company_a_id
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_a,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_b_id}:issue:#{issue.id}"
               )
    end
  end

  describe "join company:<id>:issue:<id> with session socket" do
    test "joins successfully when issue belongs to user company" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Session Issue Co #{unique}", slug: "sic-#{unique}"})

      {:ok, user} =
        Users.create_user(%{
          name: "User #{unique}",
          email: "user-sic-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _membership} =
        Companies.create_membership(%{company_id: company.id, user_id: user.id, role: "member"})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Session Issue",
          company_id: company.id
        })

      {:ok, socket} = connect_session(company.id, user.id)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company.id}:issue:#{issue.id}"
               )
    end

    test "rejects foreign and nonexistent issue for session user" do
      unique = System.unique_integer([:positive])

      {:ok, company_a} =
        Companies.create_company(%{name: "Company A #{unique}", slug: "co-ia-#{unique}"})

      {:ok, company_b} =
        Companies.create_company(%{name: "Company B #{unique}", slug: "co-ib-#{unique}"})

      {:ok, user} =
        Users.create_user(%{
          name: "User #{unique}",
          email: "user-iab-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _membership} =
        Companies.create_membership(%{company_id: company_a.id, user_id: user.id, role: "member"})

      {:ok, foreign_issue} =
        Issues.create_issue(%{
          title: "Foreign issue",
          company_id: company_b.id
        })

      {:ok, socket} = connect_session(company_a.id, user.id)
      nonexistent_id = Ecto.UUID.generate()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a.id}:issue:#{foreign_issue.id}"
               )

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a.id}:issue:#{nonexistent_id}"
               )
    end
  end

  describe "handle_in ping" do
    test "replies with pong" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Ping issue",
          company_id: company_id
        })

      {:ok, _, socket} =
        subscribe_and_join(
          socket,
          CymphoWeb.CompanyChannel,
          "company:#{company_id}:issue:#{issue.id}"
        )

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{pong: true}
    end
  end
end
