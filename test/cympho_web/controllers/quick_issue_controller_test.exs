defmodule CymphoWeb.QuickIssueControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Proxies
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

      issue = Repo.one!(from i in Issue, where: i.title == ^title)
      assert redirected_to(conn) == ~p"/issues/#{issue.id}"
      assert issue.company_id == company.id
      assert issue.project_id == project.id
      assert issue.assignee_id == agent.id
      assert issue.assigned_role == "ceo"
      assert issue.status == :todo
    end

    test "creates a mission-linked issue and inherits the goal project", %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn)

      unique = System.unique_integer([:positive])

      {:ok, project} =
        Projects.create_project(%{
          name: "Quick Goal Project #{unique}",
          prefix: unique_prefix("QG", unique),
          company_id: company.id
        })

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Quick Goal Mission #{unique}",
          goal_type: :mission,
          status: "active",
          company_id: company.id,
          project_id: project.id
        })

      title = "Quick goal-linked issue #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "goal_id" => mission.id,
          "project_id" => "",
          "status" => "todo"
        })

      issue = Repo.one!(from i in Issue, where: i.title == ^title)
      assert redirected_to(conn) == ~p"/issues/#{issue.id}"
      assert issue.company_id == company.id
      assert issue.goal_id == mission.id
      assert issue.project_id == project.id
      assert issue.lineage["goal_id"] == mission.id
      assert issue.lineage["mission_id"] == mission.id
    end

    test "defaults a blank assignee to the company CEO and opens the issue", %{conn: conn} do
      {conn, _user, company} = register_and_log_in_user(conn)

      unique = System.unique_integer([:positive])

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Default Quick CEO #{unique}",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      title = "Quick prompt owner handoff #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "assignee_id" => "",
          "status" => "todo"
        })

      issue = Repo.one!(from i in Issue, where: i.title == ^title)
      assert redirected_to(conn) == ~p"/issues/#{issue.id}"
      assert issue.company_id == company.id
      assert issue.assignee_id == ceo.id
      assert issue.assigned_role == "ceo"
      assert issue.status == :todo
      assert issue.priority == :medium
    end

    test "creates a swarm issue from quick-create and routes through CEO/CTO", %{conn: conn} do
      {conn, _user, company} =
        register_and_log_in_user(conn, %{role: "owner", is_board_member: true})

      unique = System.unique_integer([:positive])

      {:ok, ceo} =
        Agents.create_agent(%{
          name: "Quick Swarm CEO #{unique}",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, cto} =
        Agents.create_agent(%{
          name: "Quick Swarm CTO #{unique}",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, designer} =
        Agents.create_agent(%{
          name: "Quick Swarm Designer #{unique}",
          role: :designer,
          status: :idle,
          company_id: company.id
        })

      {:ok, _proxy_a} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "quick-egress-a",
          proxy_type: "socks5",
          host: "127.0.0.1",
          port: 10_901
        })

      {:ok, _proxy_b} =
        Proxies.create_proxy_profile(%{
          company_id: company.id,
          name: "quick-egress-b",
          proxy_type: "http",
          host: "127.0.0.1",
          port: 10_902
        })

      title = "Quick modal swarm #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "assignee_id" => designer.id,
          "status" => "todo",
          "swarm" => %{
            "enabled" => "true",
            "agent_count" => "3",
            "mix" => """
            product_manager | openai_chat | qwen3.6-flash | low
            designer | codex | gpt-5.3-high-fast | high
            researcher | claude_code | sonnet | medium
            """,
            "proxy_mode" => "random"
          }
        })

      parent = Repo.one!(from i in Issue, where: i.title == ^title)
      assert redirected_to(conn) == ~p"/issues/#{parent.id}"
      assert parent.status == :blocked
      assert parent.assignee_id == ceo.id
      assert parent.assigned_role == "ceo"
      assert parent.monitor_state["swarm"]["status"] == "launched"

      assert parent.monitor_state["swarm"]["proxy"]["mode"] == "random"

      assert parent.monitor_state["swarm"]["proxy"]["pool"] == [
               "quick-egress-a",
               "quick-egress-b"
             ]

      reasoning_efforts = Enum.map(parent.monitor_state["swarm"]["mix"], & &1["reasoning_effort"])
      assert length(reasoning_efforts) == 3
      assert Enum.all?(reasoning_efforts, &(&1 in ["low", "high", "medium"]))

      children = Issues.list_child_issues(parent.id)
      assert Enum.count(children, &(&1.origin_type == "swarm_worker")) == 3

      assert Enum.any?(
               children,
               &(&1.origin_type == "swarm_cto_review" and &1.assignee_id == cto.id)
             )
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

    test "rejects a stale quick-create form after the session company changes", %{conn: conn} do
      {conn, _user, current_company} = register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])

      {:ok, stale_company} =
        Cympho.Companies.create_company(%{
          name: "Stale Quick Co #{unique}",
          slug: "stale-quick-co-#{unique}"
        })

      title = "Stale tab issue #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "company_id" => stale_company.id,
          "status" => "todo"
        })

      assert redirected_to(conn) == "/issues"
      assert current_company.id != stale_company.id

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "The company changed in another tab. Review the current company and try again."

      refute Repo.exists?(from i in Issue, where: i.title == ^title)
    end

    test "rejects cross-company quick-create goals", %{conn: conn} do
      {conn, _user, _company} = register_and_log_in_user(conn)
      unique = System.unique_integer([:positive])

      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Quick Goal Co #{unique}",
          slug: "other-quick-goal-co-#{unique}"
        })

      {:ok, other_goal} =
        Goals.create_goal(%{
          title: "Other Company Mission #{unique}",
          goal_type: :mission,
          status: "active",
          company_id: other_company.id
        })

      title = "Forbidden quick modal goal issue #{unique}"

      conn =
        post(conn, "/issues/quick-create", %{
          "title" => title,
          "goal_id" => other_goal.id,
          "status" => "todo"
        })

      assert redirected_to(conn) == "/issues"

      assert Phoenix.Flash.get(conn.assigns.flash, :error) ==
               "Choose a goal from this company."

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
