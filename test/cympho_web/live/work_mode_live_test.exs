defmodule CymphoWeb.WorkModeLiveTest do
  use CymphoWeb.LiveCase, async: true

  import Phoenix.LiveViewTest

  alias Cympho.{Agents, Companies, IssueThreadInteractions, Issues, Repo}
  alias Cympho.Issues.IssueThreadInteraction

  test "full issue creation explains and persists the selected mode", %{
    current_company: company
  } do
    {:ok, view, html} = live(conn(), "/issues/new")

    assert html =~ "How should the team begin?"
    assert html =~ "Start work"
    assert html =~ "Plan first"
    assert html =~ "Ask me first"
    assert has_element?(view, "[data-testid='issue-work-mode'] .ui-advanced-only")
    assert html =~ ~s(id="quick-create-work-mode")

    title = "Plan-first LiveView #{System.unique_integer([:positive])}"

    result =
      render_submit(view, "save", %{
        "issue" => %{
          "title" => title,
          "description" => "Prepare a reviewable plan before changing anything.",
          "work_mode" => "planning"
        }
      })

    created =
      Issues.list_issues(%{company_id: company.id})
      |> Enum.find(&(&1.title == title))

    assert created.work_mode == :planning
    assert {:error, {:live_redirect, %{to: "/issues/" <> _rest}}} = result
  end

  test "issue detail updates the work contract and rejects invalid values", %{
    current_company: company
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Change the work contract",
        status: :todo
      })

    {:ok, view, html} = live(conn(), "/issues/#{issue.id}")

    assert html =~ "Begin with"
    assert has_element?(view, "[data-testid='issue-work-mode-control']")
    assert has_element?(view, "[data-testid='issue-work-mode-control'] + .ui-advanced-only")

    html = render_hook(view, "combobox_work_mode", %{"selected" => "ask"})
    assert html =~ "Work mode updated"
    assert Issues.get_issue!(issue.id).work_mode == :ask

    html = render_hook(view, "update_work_mode", %{"work_mode" => "unrestricted"})
    assert html =~ "Choose a valid work mode"
    assert Issues.get_issue!(issue.id).work_mode == :ask
  end

  test "issue detail cannot resolve an interaction belonging to another company", %{
    current_company: company
  } do
    unique = System.unique_integer([:positive])

    {:ok, local_issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "Local issue #{unique}",
        status: :todo
      })

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Foreign interaction #{unique}",
        slug: "foreign-interaction-#{unique}"
      })

    {:ok, other_agent} =
      Agents.create_agent(%{
        company_id: other_company.id,
        name: "Foreign agent #{unique}",
        role: :cto
      })

    {:ok, other_issue} =
      Issues.create_issue(%{
        company_id: other_company.id,
        title: "Foreign issue #{unique}",
        status: :blocked,
        work_mode: :planning,
        assignee_id: other_agent.id
      })

    {:ok, foreign_interaction} =
      IssueThreadInteractions.create_interaction(%{
        issue_id: other_issue.id,
        kind: :request_confirmation,
        created_by_agent_id: other_agent.id,
        payload: %{"message" => "Approve the foreign plan?"}
      })

    {:ok, view, _html} = live(conn(), "/issues/#{local_issue.id}")

    html =
      render_hook(view, "resolve_interaction", %{
        "id" => foreign_interaction.id,
        "status" => "accepted"
      })

    assert html =~ "Interaction not found"
    assert Repo.get!(IssueThreadInteraction, foreign_interaction.id).status == :pending
    assert Issues.get_issue!(other_issue.id).work_mode == :planning
  end
end
