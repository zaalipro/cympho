defmodule Cympho.IssueDigestTest do
  use Cympho.DataCase, async: true

  alias Cympho.Comments.Comment
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.IssueDigest
  alias Cympho.Issues.Issue
  alias Cympho.Projects.Project
  alias Cympho.WorkProducts.IssueWorkProduct

  test "summarizes a not-started issue" do
    digest =
      IssueDigest.build(%Issue{
        title: "Launch onboarding",
        status: :todo,
        priority: :medium,
        comments: []
      })

    assert digest.state == :not_started
    assert digest.label == "Not started"
    assert digest.latest_signal == "No agent signal yet."
    assert digest.coverage.label == "Low evidence"
    assert digest.next_action =~ "Start with the CEO"

    assert digest.activity_summary.what_happened ==
             "No owner-visible activity has been captured yet."

    assert digest.activity_summary.comment_mix == []
    refute digest.quality.ready?
    assert Enum.any?(digest.quality.gaps, &(&1.key == :agent_note))
    assert Enum.any?(digest.quality.gaps, &(&1.key == :owner_summary))
    assert Enum.any?(digest.quality.gaps, &(&1.key == :work_product))

    assert Enum.map(digest.completion_contract, & &1.role) == [
             "Engineer / delivery owner",
             "CTO / reviewer",
             "CEO / owner liaison"
           ]

    assert Enum.all?(digest.completion_contract, &(&1.status == :neutral))
  end

  test "surfaces failed runs as the highest-priority signal" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{title: "Runtime issue", status: :in_progress, comments: []},
        [
          %Run{
            status: "failed",
            adapter: "codex",
            error_reason: "OPENAI_API_KEY not set",
            inserted_at: now,
            completed_at: now
          }
        ],
        [],
        []
      )

    assert digest.state == :needs_attention
    assert digest.headline == "1 runtime failure needs review."
    assert digest.latest_signal == "Latest blocker: OPENAI_API_KEY not set"
    assert digest.next_action =~ "Open the failed run details"
    assert Enum.any?(digest.quality.gaps, &(&1.key == :runtime_verification))
    assert digest.quality.attention_count >= 1

    runtime = Enum.find(digest.role_run_summaries, &(&1.key == :runtime))
    delivery = Enum.find(digest.role_run_summaries, &(&1.key == :delivery))

    assert runtime.status == :blocked
    assert runtime.summary =~ "failed runtime"
    assert delivery.status == :blocked
  end

  test "marks artifact-backed agent work as ready for review" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Ready issue",
          status: :todo,
          description: "Implement the feature.",
          github_pr_number: 42,
          project: %Project{repo_url: "https://github.com/acme/app"},
          comments: [
            %Comment{
              author_type: "agent",
              body:
                "[delivery] What happened: implemented the feature. Files changed: feature modules. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
              inserted_at: now
            }
          ]
        },
        [
          %Run{
            status: "completed",
            adapter: "codex",
            continuation_summary: "Tests passed.",
            inserted_at: now,
            completed_at: now
          }
        ],
        [
          %IssueWorkProduct{
            kind: "code_change",
            title: "Implementation PR",
            inserted_at: DateTime.add(now, 1, :second)
          }
        ],
        []
      )

    assert digest.state == :ready_for_review
    assert digest.coverage.label == "Strong evidence"
    assert digest.latest_signal == "Latest artifact: Implementation PR"
    assert digest.next_action =~ "Move the issue to review"
    assert digest.metrics.owner_relevant_comments == 1
    assert Enum.any?(digest.activity_summary.comment_mix, &(&1.category == :delivery))
    assert digest.activity_summary.current_state =~ "Ready for review"
    assert digest.quality.ready?
    assert digest.quality.gaps == []
    assert Enum.find(digest.completion_contract, &(&1.key == :delivery_contract)).status == :ok
    assert Enum.find(digest.completion_contract, &(&1.key == :review_contract)).status == :missing
    refute digest.review_readiness.ready?
    assert digest.review_readiness.summary == "1 gate blocking CTO/CEO approval."
    assert Enum.any?(digest.review_readiness.blockers, &(&1.key == :review_decision))
  end

  test "marks bad PR quality as a review blocker" do
    digest =
      IssueDigest.build(
        %Issue{
          title: "Bad PR issue",
          status: :todo,
          description: "Implement the feature.",
          github_pr_url: "https://github.com/acme/app/pull/42",
          monitor_state: %{
            "pr_quality" => %{
              "status" => "attention",
              "summary" => "2 PR contract gaps need fixes.",
              "gaps" => [
                %{"label" => "Branch name", "detail" => "Expected branch to include CYM-42."}
              ]
            }
          },
          comments: [
            %Comment{
              author_type: "agent",
              body:
                "[delivery] What happened: implemented. Files changed: app. Verification: tests. Risks: low. Current state: ready. Next decision: review."
            }
          ]
        },
        [],
        [%IssueWorkProduct{kind: "code_change", title: "Implementation"}],
        []
      )

    assert Enum.any?(
             digest.quality.gaps,
             &(&1.key == :code_reference and &1.label == "PR quality")
           )

    assert Enum.any?(digest.review_readiness.blockers, &(&1.key == :code_reference))
  end

  test "completion contract records latest evidence, actor, and timestamp" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    delivery_id = Ecto.UUID.generate()
    cto_id = Ecto.UUID.generate()
    ceo_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(
        %Issue{
          title: "Audited issue",
          status: :in_review,
          description: "Implement and review the feature.",
          comments: [
            %Comment{
              author_type: "agent",
              author_id: delivery_id,
              body:
                "[delivery] What happened: implemented the feature. Files changed: feature modules. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
              inserted_at: now
            },
            %Comment{
              author_type: "agent",
              author_id: cto_id,
              body:
                "[review] Verdict: accepted. What happened: verified the evidence. Verification: tests passed. Gaps: none. Follow-up issues: none. Next decision: owner update.",
              inserted_at: DateTime.add(now, 2, :second)
            },
            %Comment{
              author_type: "agent",
              author_id: ceo_id,
              body:
                "[owner_update] What happened: owner-facing launch status is ready. Business status: not shipped. Current state: reviewed. Next decision: close. Owner decision needed: none.",
              inserted_at: DateTime.add(now, 3, :second)
            }
          ]
        },
        [],
        [
          %IssueWorkProduct{
            created_by_agent_id: delivery_id,
            kind: "document",
            title: "Implementation bundle",
            inserted_at: DateTime.add(now, 1, :second)
          }
        ],
        [],
        [
          %Agent{id: delivery_id, name: "Delivery Agent", role: :engineer},
          %Agent{id: cto_id, name: "Review Captain", role: :cto},
          %Agent{id: ceo_id, name: "CEO", role: :ceo}
        ]
      )

    delivery = Enum.find(digest.completion_contract, &(&1.key == :delivery_contract))
    review = Enum.find(digest.completion_contract, &(&1.key == :review_contract))
    owner = Enum.find(digest.completion_contract, &(&1.key == :owner_contract))

    assert delivery.evidence.label == "Work product"
    assert delivery.evidence.actor == "Delivery Agent"
    assert delivery.evidence.summary =~ "Implementation bundle"
    assert delivery.evidence.timestamp == DateTime.add(now, 1, :second)

    assert review.evidence.label == "Review"
    assert review.evidence.actor == "Review Captain"
    assert review.evidence.summary =~ "verified the evidence"

    assert owner.evidence.label == "Owner update"
    assert owner.evidence.actor == "CEO"
    assert owner.evidence.summary =~ "owner-facing launch status"
  end

  test "requires an explicit delivery tag before review when evidence exists" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Untagged delivery",
          status: :in_progress,
          description: "Implement the feature.",
          comments: [
            %Comment{
              author_type: "agent",
              body: "Implemented the feature and verified tests.",
              inserted_at: now
            }
          ]
        },
        [
          %Run{
            status: "completed",
            adapter: "codex",
            continuation_summary: "Tests passed.",
            inserted_at: now,
            completed_at: now
          }
        ],
        [
          %IssueWorkProduct{
            kind: "document",
            title: "Implementation notes",
            inserted_at: now
          }
        ],
        []
      )

    assert Enum.any?(digest.review_readiness.blockers, &(&1.key == :delivery_comment))

    assert [%{key: :delivery_comment}] =
             IssueDigest.review_status_blockers(
               %Issue{
                 title: "Untagged delivery",
                 status: :in_progress,
                 description: "Implement the feature.",
                 comments: [
                   %Comment{
                     author_type: "agent",
                     body: "Implemented the feature and verified tests.",
                     inserted_at: now
                   }
                 ]
               },
               :in_review,
               [
                 %Run{
                   status: "completed",
                   adapter: "codex",
                   inserted_at: now,
                   completed_at: now
                 }
               ],
               [
                 %IssueWorkProduct{
                   kind: "document",
                   title: "Implementation notes",
                   inserted_at: now
                 }
               ],
               []
             )
  end

  test "tagged delivery comments must include required handoff fields" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Thin delivery",
          status: :in_progress,
          description: "Implement the feature.",
          comments: [
            %Comment{
              author_type: "agent",
              body: "[delivery] Done.",
              inserted_at: now
            }
          ]
        },
        [
          %Run{
            status: "completed",
            adapter: "codex",
            inserted_at: now,
            completed_at: now
          }
        ],
        [%IssueWorkProduct{kind: "document", title: "Evidence", inserted_at: now}],
        []
      )

    delivery = Enum.find(digest.completion_contract, &(&1.key == :delivery_contract))

    assert delivery.status == :attention
    assert "Verification" in delivery.missing_fields
    assert Enum.any?(digest.review_readiness.blockers, &(&1.key == :delivery_comment))
  end

  test "requires CEO owner update before closing delegated parent work" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    issue = %Issue{
      title: "Delegated parent",
      status: :in_review,
      description: "Parent issue with child work.",
      comments: [
        %Comment{
          author_type: "agent",
          body:
            "[delivery] What happened: child work completed. Files changed: child issue artifacts. Verification: checked completed child work. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          inserted_at: DateTime.add(now, -2, :minute)
        },
        %Comment{
          author_type: "agent",
          body:
            "[review] Verdict: accepted. What happened: CTO reviewed the delegated work. Verification: child work is closed. Gaps: none. Follow-up issues: none. Next decision: CEO owner update.",
          inserted_at: DateTime.add(now, -1, :minute)
        }
      ]
    }

    blockers =
      IssueDigest.review_status_blockers(
        issue,
        :done,
        [
          %Run{
            status: "completed",
            adapter: "codex",
            inserted_at: now,
            completed_at: now
          }
        ],
        [%IssueWorkProduct{kind: "document", title: "Rollup", inserted_at: now}],
        [%Issue{status: :done, title: "Closed child"}]
      )

    assert Enum.any?(blockers, &(&1.key == :ceo_owner_update))
  end

  test "marks review readiness ready when evidence and CTO/CEO review exist" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Reviewable issue",
          status: :in_review,
          description: "Implement and review the feature.",
          github_pr_number: 7,
          project: %Project{repo_url: "https://github.com/acme/app"},
          comments: [
            %Comment{
              author_type: "agent",
              body:
                "[delivery] What happened: implemented the change. Files changed: feature modules. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
              inserted_at: DateTime.add(now, -2, :minute)
            },
            %Comment{
              author_type: "agent",
              body:
                "[review] Verdict: accepted. What happened: CTO verified the PR and tests. Verification: tests passed. Gaps: none. Follow-up issues: none. Next decision: approval.",
              inserted_at: DateTime.add(now, -1, :minute)
            }
          ]
        },
        [
          %Run{
            status: "completed",
            adapter: "codex",
            continuation_summary: "Tests passed.",
            inserted_at: now,
            completed_at: now
          }
        ],
        [
          %IssueWorkProduct{
            kind: "code_change",
            title: "Reviewed PR",
            inserted_at: now
          }
        ],
        []
      )

    assert digest.review_readiness.ready?
    assert digest.review_readiness.label == "Ready for approval"
    assert digest.review_readiness.summary == "All approval gates are satisfied."
    assert Enum.find(digest.completion_contract, &(&1.key == :delivery_contract)).status == :ok
    assert Enum.find(digest.completion_contract, &(&1.key == :review_contract)).status == :ok

    assert Enum.all?(
             digest.review_readiness.gates,
             &(&1.status in [:ok, :neutral])
           )
  end

  test "classifies comments into owner-readable activity buckets" do
    digest =
      IssueDigest.build(%Issue{
        title: "Noisy issue",
        status: :in_progress,
        comments: [
          %Comment{author_type: "agent", body: "[delivery] Implemented the workflow."},
          %Comment{author_type: "agent", body: "Blocked on missing provider credentials."},
          %Comment{author_type: "user", body: "Can we launch this today?"},
          %Comment{author_type: "agent", body: "Looking around."}
        ]
      })

    assert IssueDigest.comment_category(%Comment{
             author_type: "agent",
             body: "[review] Tests passed."
           }) ==
             :review

    assert IssueDigest.comment_category(%Comment{
             author_type: "agent",
             body:
               "Owner request accepted. I am splitting this into product and engineering work."
           }) ==
             :owner_update

    assert digest.metrics.owner_relevant_comments == 3
    assert digest.metrics.routine_comments == 1
    assert digest.metrics.comment_categories.delivery == 1
    assert digest.metrics.comment_categories.blocked == 1
    assert digest.metrics.comment_categories.owner_input == 1

    assert Enum.map(digest.activity_summary.comment_mix, & &1.category) == [
             :blocked,
             :delivery,
             :owner_input,
             :routine
           ]

    assert digest.activity_summary.what_happened =~ "3 owner-relevant notes"
  end

  test "rolls up long comment threads while preserving latest meaningful update" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(%Issue{
        title: "Long thread",
        status: :in_progress,
        comments: [
          %Comment{
            author_type: "agent",
            body: "Checking the repo.",
            inserted_at: DateTime.add(now, -6, :minute)
          },
          %Comment{
            author_type: "agent",
            body: "[handoff] What happened: split implementation across two tickets.",
            inserted_at: DateTime.add(now, -5, :minute)
          },
          %Comment{
            author_type: "agent",
            body: "Still reading context.",
            inserted_at: DateTime.add(now, -4, :minute)
          },
          %Comment{
            author_type: "agent",
            body: "[delivery] What happened: finished the smallest UI patch.",
            inserted_at: DateTime.add(now, -3, :minute)
          },
          %Comment{
            author_type: "agent",
            body: "Looking at logs.",
            inserted_at: DateTime.add(now, -2, :minute)
          }
        ]
      })

    assert digest.thread_rollup.active?
    assert digest.thread_rollup.visible_signal_count == 2
    assert digest.thread_rollup.hidden_routine_count == 3
    assert digest.thread_rollup.headline =~ "folding 3 routine notes"
    assert digest.thread_rollup.audit_hint =~ "full audit trail"
    assert digest.thread_rollup.latest_meaningful.label == "Delivery"
    assert digest.thread_rollup.latest_meaningful.body =~ "finished the smallest UI patch"
  end

  test "groups agent contributions by role, evidence, and latest owner signal" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    engineer_id = Ecto.UUID.generate()
    cto_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(
        %Issue{
          title: "Contribution issue",
          status: :in_review,
          comments: [
            %Comment{
              author_type: "agent",
              author_id: engineer_id,
              body: "[delivery] What happened: implemented the onboarding flow.",
              inserted_at: DateTime.add(now, -3, :minute)
            },
            %Comment{
              author_type: "agent",
              author_id: cto_id,
              body: "[review] What happened: reviewed the delivery and requested owner approval.",
              inserted_at: DateTime.add(now, -1, :minute)
            }
          ]
        },
        [
          %Run{
            agent_id: engineer_id,
            status: "completed",
            adapter: "codex",
            inserted_at: DateTime.add(now, -2, :minute),
            completed_at: DateTime.add(now, -2, :minute)
          }
        ],
        [
          %IssueWorkProduct{
            created_by_agent_id: engineer_id,
            kind: "code_change",
            title: "Onboarding PR",
            inserted_at: DateTime.add(now, -2, :minute)
          }
        ],
        [],
        [
          %Agent{id: engineer_id, name: "Engineer 1", role: :engineer},
          %Agent{id: cto_id, name: "CTO", role: :cto}
        ]
      )

    assert [cto, engineer] = digest.contributions
    assert cto.name == "CTO"
    assert cto.role_label == "cto"
    assert cto.status == :review
    assert cto.latest_comment.body =~ "reviewed the delivery"

    assert engineer.name == "Engineer 1"
    assert engineer.status == :delivery
    assert engineer.counts.successful_runs == 1
    assert engineer.counts.artifacts == 1
    assert [%{title: "Onboarding PR"}] = engineer.artifacts
    assert engineer.summary =~ "Delivery signal"

    summaries = Map.new(digest.role_run_summaries, &{&1.key, &1})

    assert summaries.delivery.status == :delivery
    assert summaries.delivery.owner == "Engineer 1"
    assert summaries.delivery.summary =~ "tagged completion note"
    assert summaries.review.status == :review
    assert summaries.review.owner == "CTO"
    assert summaries.owner_update.status == :waiting
    assert summaries.runtime.status == :decision
  end
end
