defmodule CymphoWeb.Components.IssueDigestTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Cympho.Agents.Agent
  alias Cympho.Comments.Comment
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.WorkProducts.IssueWorkProduct

  defp render_digest(assigns) do
    render_component(
      &CymphoWeb.Components.IssueDigest.issue_digest_panel/1,
      Keyword.merge(
        [
          issue: %Issue{title: "Digest issue", status: :todo, priority: :medium, comments: []},
          runs: [],
          work_products: [],
          child_issues: [],
          agents: [],
          review_gate_actions: [],
          review_nudges: []
        ],
        assigns
      )
    )
  end

  defp render_digest_card(issue, assigns \\ []) do
    render_component(
      &CymphoWeb.Components.IssueDigest.issue_digest_card/1,
      Keyword.merge(
        [
          issue: issue,
          density: "compact",
          variant: "inline"
        ],
        assigns
      )
    )
  end

  test "renders linked mission context on compact digest cards" do
    html =
      render_digest_card(%Issue{
        title: "Mission card",
        status: :todo,
        priority: :medium,
        comments: [],
        goal_id: Ecto.UUID.generate(),
        goal: %Goal{title: "Raise activation quality", goal_type: :mission}
      })

    assert html =~ "Mission: Raise activation quality"
    assert html =~ "Mission context: Raise activation quality"
  end

  test "renders project-only and floating mission context fallbacks" do
    project_only =
      render_digest_card(%Issue{
        title: "Project card",
        status: :todo,
        priority: :medium,
        comments: [],
        project_id: Ecto.UUID.generate()
      })

    floating =
      render_digest_card(%Issue{
        title: "Floating card",
        status: :todo,
        priority: :medium,
        comments: []
      })

    assert project_only =~ "Project only"
    assert project_only =~ "No mission goal is linked"
    assert floating =~ "Floating"
    assert floating =~ "No mission goal or project is linked"
  end

  test "renders missing-url artifacts without placeholder links" do
    agent_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    html =
      render_digest(
        issue: %Issue{
          title: "Artifact issue",
          status: :todo,
          priority: :high,
          description: "Ship the artifact flow.",
          comments: [
            %Comment{
              author_type: "agent",
              author_id: agent_id,
              body:
                "[delivery] What happened: produced evidence. Files changed: app. Verification: checked manually. Risks: none known. Current state: ready. Next decision: review. Restart packet: reviewer should inspect the app evidence and manual check.",
              inserted_at: now
            }
          ]
        },
        work_products: [
          %IssueWorkProduct{
            created_by_agent_id: agent_id,
            kind: "code_change",
            title: "Offline diff",
            inserted_at: now
          },
          %IssueWorkProduct{
            created_by_agent_id: agent_id,
            kind: "url",
            title: "Run log",
            url: "https://example.com/run-log",
            inserted_at: now
          }
        ],
        agents: [%Agent{id: agent_id, name: "Engineer", role: :engineer}]
      )

    assert html =~ "Offline diff"
    assert html =~ "Run log"
    assert html =~ ~s(href="https://example.com/run-log")
    refute html =~ ~s(href="#")
  end

  test "renders a copyable issue handoff packet" do
    agent_id = Ecto.UUID.generate()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    html =
      render_digest(
        issue: %Issue{
          identifier: "CYM-99",
          title: "Handoff issue",
          status: :in_review,
          priority: :high,
          description: "Owner wants the next agent to continue safely.",
          comments: [
            %Comment{
              author_type: "agent",
              author_id: agent_id,
              body:
                "[delivery] What happened: implemented the handoff packet. Files changed: issue_memory.ex. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect issue_memory.ex and the passing tests.",
              inserted_at: now
            }
          ]
        },
        work_products: [
          %IssueWorkProduct{
            created_by_agent_id: agent_id,
            kind: "code_change",
            title: "Handoff implementation",
            inserted_at: now
          }
        ],
        agents: [%Agent{id: agent_id, name: "Engineer", role: :engineer}]
      )

    assert html =~ "Copy handoff"
    assert html =~ "Handoff copied"
    assert html =~ "Copy the distilled issue memory"
    assert html =~ "Issue handoff context"
    assert html =~ "# Issue handoff: CYM-99 - Handoff issue"
    assert html =~ "- Actions taken: implemented the handoff packet."
    assert html =~ "Current state"
    assert html =~ "ready for review."
    assert html =~ "- Next decision: CTO review."
    assert html =~ "Restart packet"
    assert html =~ "CTO should inspect issue_memory.ex and the passing tests."
    assert html =~ "- Restart packet: CTO should inspect issue_memory.ex and the passing tests."
  end

  test "hides generic runtime launch actions for swarm CTO gates" do
    issue_id = Ecto.UUID.generate()
    cto_id = Ecto.UUID.generate()

    html =
      render_digest(
        issue: %Issue{
          id: issue_id,
          identifier: "AIL-129",
          title: "Synthesize swarm delivery",
          status: :todo,
          priority: :medium,
          origin_type: "swarm_cto_review",
          assignee_id: cto_id,
          assigned_role: "cto",
          assignee: %Agent{id: cto_id, name: "CTO", role: :cto},
          monitor_state: %{"swarm" => %{"role" => "cto_synthesis"}},
          comments: []
        },
        review_gate_actions: [
          %{
            type: :live_event,
            event: "prioritize_dispatch",
            label: "Queue focused dispatch",
            detail: "Pin this issue as the next focused dispatch candidate.",
            tone: :primary,
            enabled?: true,
            gate_label: "Runtime verification"
          },
          %{
            type: :copy,
            copy_text: "CYMPHO_DISPATCH_ONLY_ISSUE_ID=#{issue_id}",
            label: "Copy focused command",
            success_label: "Copied",
            gate_label: "Runtime verification"
          },
          %{
            type: :anchor,
            href: "/operations#runtime-launch-checklist",
            label: "Open launch checklist",
            gate_label: "Runtime verification"
          }
        ]
      )

    assert html =~ "CTO review ready"
    assert html =~ "Worker packets are ready for CTO synthesis."
    refute html =~ "Queue focused dispatch"
    refute html =~ "Copy focused command"
    refute html =~ "Open launch checklist"
    assert html =~ "Copy handoff"
    assert html =~ "Open raw timeline"
  end
end
