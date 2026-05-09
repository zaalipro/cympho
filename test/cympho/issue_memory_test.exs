defmodule Cympho.IssueMemoryTest do
  use ExUnit.Case, async: true

  alias Cympho.Agents.Agent
  alias Cympho.Comments.Comment
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.IssueMemory
  alias Cympho.Issues.Issue
  alias Cympho.WorkProducts.IssueWorkProduct

  test "extracts structured fields from tagged agent comments" do
    body =
      "[delivery] What happened: implemented the checkout flow. Files changed: checkout_live.ex, checkout_test.exs. Verification: focused tests passed. Risks: payment edge cases. Current state: ready for CTO review. Next decision: CTO review."

    assert IssueMemory.extract_fields(body) == %{
             "What happened" => "implemented the checkout flow.",
             "Files changed" => "checkout_live.ex, checkout_test.exs.",
             "Verification" => "focused tests passed.",
             "Risks" => "payment edge cases.",
             "Current state" => "ready for CTO review.",
             "Next decision" => "CTO review."
           }
  end

  test "builds an owner-readable memory packet from comments, runs, and artifacts" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    engineer = %Agent{id: "agent-1", name: "Engineer 1", role: :engineer}

    issue = %Issue{
      title: "Launch checkout",
      description: "Owner wants a guided checkout flow.",
      status: :in_progress,
      comments: [
        %Comment{
          author_type: "agent",
          author_id: engineer.id,
          body:
            "[delivery] What happened: implemented checkout. Files changed: checkout_live.ex. Verification: focused tests passed. Risks: payments need production smoke. Current state: ready for CTO review. Next decision: CTO review.",
          inserted_at: now
        },
        %Comment{
          author_type: "system",
          body: "Routine heartbeat",
          inserted_at: DateTime.add(now, -1, :minute)
        }
      ]
    }

    memory =
      IssueMemory.build(
        issue,
        [
          %Run{
            status: "completed",
            adapter: "codex",
            continuation_summary: "Focused tests passed.",
            completed_at: now
          }
        ],
        [
          %IssueWorkProduct{
            kind: "code_change",
            title: "Checkout PR",
            created_by_agent_id: engineer.id,
            inserted_at: now
          }
        ],
        [],
        [engineer]
      )

    assert memory.objective == "Owner wants a guided checkout flow."
    assert memory.what_happened == "implemented checkout."
    assert memory.files_changed == "checkout_live.ex."
    assert memory.validation == "focused tests passed."
    assert memory.risks == "payments need production smoke."
    assert memory.current_state == "ready for CTO review."
    assert memory.next_decision == "CTO review."
    assert memory.noise_summary =~ "Folded 1 routine note"
    assert Enum.any?(memory.stages, &(&1.title == "Engineer delivery"))
    assert memory.quality.status == :ok
    assert memory.quality.score == 100
  end

  test "scores noisy issue memory and exposes a summary contract gap" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    engineer = %Agent{id: "agent-1", name: "Engineer 1", role: :engineer}

    issue = %Issue{
      id: "issue-1",
      title: "Noisy execution",
      status: :in_progress,
      comments: [
        %Comment{author_type: "system", body: "Routine heartbeat", inserted_at: now},
        %Comment{
          author_type: "system",
          body: "Routine dispatch check",
          inserted_at: DateTime.add(now, 1, :second)
        },
        %Comment{
          author_type: "system",
          body: "Routine adapter poll",
          inserted_at: DateTime.add(now, 2, :second)
        }
      ]
    }

    work_products = [
      %IssueWorkProduct{
        kind: "document",
        title: "Evidence bundle",
        created_by_agent_id: engineer.id,
        inserted_at: now
      }
    ]

    memory = IssueMemory.build(issue, [], work_products, [], [engineer])

    assert memory.quality.status == :missing
    assert memory.quality.nudge?
    assert Enum.any?(memory.quality.gaps, &(&1.key == :owner_ready_summary))
    assert Enum.any?(memory.quality.gaps, &(&1.key == :routine_noise))

    assert [contract] = IssueMemory.contract_gaps(issue, [], work_products, [], [engineer])
    assert contract.key == :memory_summary
    assert contract.label == "Memory health"
    assert contract.status == :missing
    assert "Owner-ready summary" in contract.missing_fields
    assert contract.prompt =~ "Collapse routine/system noise into signal"
  end

  test "a complete tagged summary restores issue memory health" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    engineer = %Agent{id: "agent-1", name: "Engineer 1", role: :engineer}

    issue = %Issue{
      id: "issue-1",
      title: "Summarized execution",
      description: "Owner wants this issue to stay readable.",
      status: :in_progress,
      comments: [
        %Comment{author_type: "system", body: "Routine heartbeat", inserted_at: now},
        %Comment{
          author_type: "system",
          body: "Routine adapter poll",
          inserted_at: DateTime.add(now, 1, :second)
        },
        %Comment{
          author_type: "agent",
          author_id: engineer.id,
          body:
            "[delivery] What happened: summarized the work. Files changed: docs. Verification: focused tests passed. Risks: none. Current state: ready. Next decision: review.",
          inserted_at: DateTime.add(now, 2, :second)
        }
      ]
    }

    work_products = [
      %IssueWorkProduct{
        kind: "document",
        title: "Evidence bundle",
        created_by_agent_id: engineer.id,
        inserted_at: now
      }
    ]

    memory = IssueMemory.build(issue, [], work_products, [], [engineer])

    assert memory.quality.status == :ok
    refute memory.quality.nudge?
    assert IssueMemory.contract_gaps(issue, [], work_products, [], [engineer]) == []
  end
end
