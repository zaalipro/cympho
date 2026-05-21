defmodule CymphoWeb.ReviewQueueLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.{Agents, Issues, Projects}

  setup do
    company = current_company()

    {:ok, project} =
      Projects.create_project(
        scoped_attrs(%{
          name: "Review Q Project",
          prefix: "RQP"
        })
      )

    {:ok, engineer} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "Engineer",
          role: :engineer,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })
      )

    {:ok, cto} =
      Agents.create_agent(
        scoped_attrs(%{
          name: "CTO",
          role: :cto,
          status: :idle,
          adapter: :process,
          config: %{"command" => "echo"}
        })
      )

    %{company: company, project: project, engineer: engineer, cto: cto}
  end

  test "shows awaiting-review issues for the current company", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, _in_review} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Awaiting CTO review",
          description: "Engineer pushed PR",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Review queue"
    assert html =~ "Awaiting CTO review"
    assert html =~ "Awaiting review"
  end

  test "lists kicked-back issues with last_reviewer info", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, _kicked} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Engineer fix needed",
          description: "Reviewer requested changes",
          status: :todo,
          priority: :medium,
          project_id: project.id,
          assigned_role: "engineer",
          last_reviewer_id: cto.id
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Kicked back to engineering"
    assert html =~ "Engineer fix needed"
    assert html =~ "last reviewed by"
  end

  test "shows spec-review initiatives that CEO seeded", %{conn: conn, project: project} do
    {:ok, _spec} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Initiative needing spec review",
          description: "CEO proposal awaiting CTO refinement",
          status: :backlog,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          monitor_state: %{
            "spec_review_required" => true,
            "proposed_role" => "engineer"
          }
        })
      )

    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "Spec review"
    assert html =~ "Initiative needing spec review"
    assert html =~ "proposed role: engineer"
  end

  test "shows empty lanes when there are no in-flight reviews", %{conn: conn} do
    {:ok, _live, html} = live(conn, "/reviews")

    assert html =~ "No issues awaiting review."
    assert html =~ "No issues currently kicked back."
    assert html =~ "No initiatives awaiting CTO spec review."
  end
end
