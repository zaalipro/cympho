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
    assert html =~ "Decision queue"
    assert html =~ "Approve and close"
    assert html =~ "Request changes"
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

  test "keeps approve-and-close behind review gates", %{conn: conn, project: project, cto: cto} do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Review without evidence",
          description: "This should not close without evidence.",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='approve_review']", "Approve and close")
      |> render_click()

    assert html =~ "Approval gates blocking closure"
    assert html =~ "Runtime verification"
    assert Issues.get_issue!(issue.id).status == :in_review
  end

  test "request changes returns review work to the rework lane", %{
    conn: conn,
    project: project,
    cto: cto
  } do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Needs reviewer changes",
          description: "Reviewer should send this back.",
          status: :in_review,
          priority: :high,
          project_id: project.id,
          assigned_role: "cto",
          assignee_id: cto.id
        })
      )

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='request_changes']", "Request changes")
      |> render_click()

    assert html =~ "Review returned to To Do for changes."
    assert html =~ "Kicked back to engineering"
    assert html =~ "Needs reviewer changes"

    updated = Issues.get_issue!(issue.id)
    assert updated.status == :todo
    assert updated.assigned_role == "engineer"
    assert is_nil(updated.assignee_id)
    assert updated.last_reviewer_id == cto.id
  end

  test "approve spec review queues initiative for execution", %{conn: conn, project: project} do
    {:ok, issue} =
      Issues.create_issue(
        scoped_attrs(%{
          title: "Spec ready to execute",
          description: "CTO has accepted the spec.",
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

    {:ok, view, _html} = live(conn, "/reviews")

    html =
      view
      |> element("button[phx-click='approve_spec']", "Approve spec")
      |> render_click()

    assert html =~ "Spec review approved and queued for execution."
    assert html =~ "No initiatives awaiting CTO spec review."

    updated = Issues.get_issue!(issue.id)
    assert updated.status == :todo
    refute Map.has_key?(updated.monitor_state, "spec_review_required")
    assert updated.monitor_state["proposed_role"] == "engineer"
  end
end
