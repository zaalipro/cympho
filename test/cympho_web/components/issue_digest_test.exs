defmodule CymphoWeb.Components.IssueDigestTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  alias Cympho.Agents.Agent
  alias Cympho.Comments.Comment
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
                "[delivery] What happened: produced evidence. Files changed: app. Verification: checked manually. Risks: none known. Current state: ready. Next decision: review.",
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
                "[delivery] What happened: implemented the handoff packet. Files changed: issue_memory.ex. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
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
    assert html =~ "- Next decision: CTO review."
  end
end
