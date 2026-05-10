defmodule CymphoWeb.QuickIssueControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Issues.Issue
  alias Cympho.Projects
  alias Cympho.Repo

  describe "create/2" do
    test "redirects anonymous browsers to login with return target", %{conn: conn} do
      conn = post(conn, "/issues/quick-create", %{"title" => "Anonymous issue"})

      assert redirected_to(conn) == "/login?return_to=%2Fissues%2Fquick-create"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Sign in to continue."
    end

    test "creates a scoped issue with project, assignee, and status", %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])
      prefix = unique_prefix("QP", unique)

      {:ok, project} =
        Projects.create_project(%{
          name: "Quick Project #{unique}",
          prefix: prefix,
          company_id: company.id
        })

      {:ok, agent} =
        Agents.create_agent(%{
          name: "Quick CEO #{unique}",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      title = "Quick modal issue #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "project_id" => project.id,
          "assignee_id" => agent.id,
          "status" => "todo"
        })

      assert redirected_to(conn) =~ "/issues/"

      issue = Repo.one!(from i in Issue, where: i.title == ^title)
      assert issue.company_id == company.id
      assert issue.project_id == project.id
      assert issue.assignee_id == agent.id
      assert issue.assigned_role == "ceo"
      assert issue.status == :todo
    end

    test "rejects cross-company quick-create references", %{conn: conn} do
      {conn, _user, _company} = register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])
      prefix = unique_prefix("OQ", unique)

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Quick Co #{unique}",
          slug: "other-quick-co-#{unique}"
        })

      {:ok, other_project} =
        Projects.create_project(%{
          name: "Other Project #{unique}",
          prefix: prefix,
          company_id: other_company.id
        })

      title = "Forbidden quick modal issue #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "project_id" => other_project.id,
          "status" => "todo"
        })

      assert redirected_to(conn) == "/issues"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Choose a project from this company."

      refute Repo.exists?(from i in Issue, where: i.title == ^title)
    end
  end

  defp unique_prefix(prefix, unique) do
    suffix =
      unique
      |> Integer.digits()
      |> Enum.map_join(fn digit -> <<?A + digit>> end)
      |> String.slice(0, 8)

    String.slice(prefix <> suffix, 0, 10)
  end
end
