defmodule CymphoWeb.CommentsChannelTest do
  use CymphoWeb.ChannelCase

  alias Cympho.{Comments, Companies, Issues, Projects, Users}

  describe "join company:<id>:project:<id> with agent socket" do
    test "joins successfully when project exists and belongs to company" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)

      {:ok, project} =
        Projects.create_project(%{
          name: "Project A",
          company_id: company_id,
          prefix: "PRA"
        })

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:project:#{project.id}"
               )
    end

    test "rejects when project belongs to a foreign company" do
      company_a_id = Ecto.UUID.generate()
      agent_a_id = Ecto.UUID.generate()
      {:ok, socket_a} = connect_jwt(company_a_id, agent_a_id)

      unique = System.unique_integer([:positive])

      {:ok, company_b} =
        Companies.create_company(%{name: "Company B #{unique}", slug: "co-b-#{unique}"})

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Project B",
          company_id: company_b.id,
          prefix: "PRB"
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_a,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a_id}:project:#{foreign_project.id}"
               )
    end

    test "rejects when project does not exist" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)
      nonexistent_id = Ecto.UUID.generate()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:project:#{nonexistent_id}"
               )
    end

    test "rejects when project ID is not a valid UUID" do
      company_id = Ecto.UUID.generate()
      agent_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, agent_id)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:project:not-a-uuid"
               )
    end

    test "rejects when company_id does not match socket" do
      company_a_id = Ecto.UUID.generate()
      company_b_id = Ecto.UUID.generate()
      agent_a_id = Ecto.UUID.generate()
      {:ok, socket_a} = connect_jwt(company_a_id, agent_a_id)

      {:ok, project} =
        Projects.create_project(%{
          name: "Project A",
          company_id: company_a_id,
          prefix: "PRA"
        })

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket_a,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_b_id}:project:#{project.id}"
               )
    end
  end

  describe "join company:<id>:project:<id> with session socket" do
    test "joins successfully when project belongs to user company" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Session Co #{unique}", slug: "session-co-#{unique}"})

      {:ok, user} =
        Users.create_user(%{
          name: "User #{unique}",
          email: "user-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _membership} =
        Companies.create_membership(%{company_id: company.id, user_id: user.id, role: "member"})

      {:ok, project} =
        Projects.create_project(%{
          name: "Session Project",
          company_id: company.id,
          prefix: "SPR"
        })

      {:ok, socket} = connect_session(company.id, user.id)

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company.id}:project:#{project.id}"
               )
    end

    test "rejects foreign and nonexistent project for session user" do
      unique = System.unique_integer([:positive])

      {:ok, company_a} =
        Companies.create_company(%{name: "Company A #{unique}", slug: "co-a-#{unique}"})

      {:ok, company_b} =
        Companies.create_company(%{name: "Company B #{unique}", slug: "co-b-#{unique}"})

      {:ok, user} =
        Users.create_user(%{
          name: "User #{unique}",
          email: "user-ab-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _membership} =
        Companies.create_membership(%{company_id: company_a.id, user_id: user.id, role: "member"})

      {:ok, foreign_project} =
        Projects.create_project(%{
          name: "Foreign Project",
          company_id: company_b.id,
          prefix: "FPR"
        })

      {:ok, socket} = connect_session(company_a.id, user.id)
      nonexistent_id = Ecto.UUID.generate()

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a.id}:project:#{foreign_project.id}"
               )

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_a.id}:project:#{nonexistent_id}"
               )
    end
  end

  describe "comment event topic contract (VAL-WEB-004)" do
    test "delivers comment creation and update events to project channel subscriber without duplicates" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Events Co #{unique}", slug: "events-co-#{unique}"})

      {:ok, user} =
        Users.create_user(%{
          name: "Author #{unique}",
          email: "author-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _membership} =
        Companies.create_membership(%{company_id: company.id, user_id: user.id, role: "member"})

      {:ok, project} =
        Projects.create_project(%{
          name: "Events Project",
          company_id: company.id,
          prefix: "EVP"
        })

      {:ok, other_project} =
        Projects.create_project(%{
          name: "Other Project",
          company_id: company.id,
          prefix: "OTP"
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Commentable Issue",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other Project Issue",
          company_id: company.id,
          project_id: other_project.id
        })

      {:ok, socket} = connect_session(company.id, user.id)

      {:ok, _reply, _joined_socket} =
        subscribe_and_join(
          socket,
          CymphoWeb.CompanyChannel,
          "company:#{company.id}:project:#{project.id}"
        )

      # 1. Create a comment on the target project's issue
      {:ok, comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          body: "Initial discussion comment",
          author_type: "user",
          author_id: user.id
        })

      # Channel subscriber receives the event
      assert_push "comment", payload, 500
      assert payload.event_type == :comment_created
      assert payload.resource_id == comment.id
      assert payload.issue_id == issue.id
      assert payload.content == "Initial discussion comment"

      # Duplicate delivery check: exactly ONE event was pushed
      refute_push "comment", _, 100

      # 2. Update the comment
      {:ok, updated_comment} =
        Comments.update_comment(comment, %{body: "Updated discussion comment"})

      assert_push "comment", update_payload, 500
      assert update_payload.event_type == :comment_updated
      assert update_payload.resource_id == updated_comment.id
      assert update_payload.content == "Updated discussion comment"

      # Duplicate delivery check: exactly ONE event was pushed
      refute_push "comment", _, 100

      # 3. Comment on an issue in another project is NOT delivered to this project channel
      {:ok, _unrelated_comment} =
        Comments.create_comment(%{
          issue_id: other_issue.id,
          body: "Comment on other project",
          author_type: "user",
          author_id: user.id
        })

      refute_push "comment", _, 100
    end
  end
end
