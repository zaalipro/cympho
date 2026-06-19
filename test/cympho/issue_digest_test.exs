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

  test "summarizes assigned todo issues without runs as pre-runtime launch work" do
    agent_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(%Issue{
        title: "Launch assigned work",
        status: :todo,
        priority: :high,
        assignee_id: agent_id,
        assignee: %Agent{id: agent_id, name: "CEO Agent", role: :ceo},
        comments: []
      })

    assert digest.state == :pre_runtime
    assert digest.label == "Launch needed"
    assert digest.headline == "Assigned, but runtime has not started yet."

    assert digest.summary ==
             "CEO Agent owns the next move, but no runtime run has produced evidence yet."

    assert digest.latest_signal == "No agent signal yet."
    assert digest.next_action =~ "Operations launch checklist"
    assert digest.next_action =~ "focused CEO command"
    assert digest.next_action =~ "digest or sidebar"
    assert digest.next_action =~ "[owner_update]"
    assert digest.next_action =~ "[handoff]"
    refute digest.next_action =~ "from the sidebar"

    assert Enum.map(digest.role_run_summaries, & &1.key) == [
             :owner_update,
             :runtime,
             :delivery,
             :review
           ]

    owner = Enum.find(digest.role_run_summaries, &(&1.key == :owner_update))
    delivery = Enum.find(digest.role_run_summaries, &(&1.key == :delivery))

    assert owner.title == "CEO first turn"
    assert owner.status == :missing
    assert owner.summary =~ "first owner-facing signal"
    assert Enum.any?(owner.evidence, &(&1.label == "handoffs"))
    assert owner.next_action =~ "Start the CEO turn"
    assert owner.next_action =~ "[owner_update]"
    assert owner.next_action =~ "[handoff]"

    assert delivery.status == :waiting
    assert delivery.summary =~ "Delivery waits for the CEO first turn"
    assert delivery.next_action == "Start the CEO turn before assigning delivery."
  end

  test "summarizes queued focused dispatch as the active pre-runtime action" do
    agent_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(%Issue{
        title: "Queued CEO launch",
        status: :todo,
        priority: :high,
        assignee_id: agent_id,
        assignee: %Agent{id: agent_id, name: "CEO Agent", role: :ceo},
        monitor_state: %{"dispatch" => %{"pinned_at" => "2026-06-09T12:00:00Z"}},
        comments: []
      })

    assert digest.state == :pre_runtime
    assert digest.next_action =~ "Focused dispatch is queued"
    assert digest.next_action =~ "Copy the focused command"
    assert digest.next_action =~ "[owner_update]"
    assert digest.next_action =~ "[handoff]"
    refute digest.next_action =~ "from the sidebar"
  end

  test "summarizes swarm CTO gates as synthesis-ready instead of generic runtime launch" do
    cto_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(%Issue{
        title: "Synthesize swarm delivery",
        status: :todo,
        priority: :medium,
        origin_type: "swarm_cto_review",
        assignee_id: cto_id,
        assigned_role: "cto",
        assignee: %Agent{id: cto_id, name: "CTO", role: :cto},
        monitor_state: %{"swarm" => %{"role" => "cto_synthesis"}},
        comments: []
      })

    assert digest.state == :swarm_cto_ready
    assert digest.label == "CTO review ready"
    assert digest.headline == "Worker packets are ready for CTO synthesis."
    assert digest.summary =~ "publish the CEO restart packet"
    assert digest.next_action =~ "Add a tagged `[review]` synthesis"
    refute digest.next_action =~ "Operations launch checklist"
    refute digest.next_action =~ "focused dispatch"

    review = Enum.find(digest.role_run_summaries, &(&1.key == :review))
    runtime = Enum.find(digest.role_run_summaries, &(&1.key == :runtime))

    assert review.status == :missing
    assert review.next_action =~ "Add `[review] Verdict"
    assert runtime.title == "Swarm evidence"
    assert runtime.status == :waiting
    assert runtime.summary =~ "Worker packets are closed"
    assert runtime.next_action =~ "do not start another generic runtime pass"
  end

  test "summarizes swarm workers as packet work instead of owner/runtime launch" do
    worker_id = Ecto.UUID.generate()

    digest =
      IssueDigest.build(%Issue{
        title: "Swarm worker packet",
        status: :todo,
        priority: :medium,
        origin_type: "swarm_worker",
        assignee_id: worker_id,
        assigned_role: "researcher",
        assignee: %Agent{id: worker_id, name: "Temporary Researcher", role: :researcher},
        monitor_state: %{"swarm" => %{"role" => "worker", "worker_index" => 1}},
        comments: []
      })

    assert digest.state == :swarm_worker_pending
    assert digest.label == "Worker packet"
    assert digest.headline =~ "Temporary worker packet"
    assert digest.next_action =~ "swarm_worker_complete"
    refute digest.next_action =~ "Operations launch checklist"

    runtime = Enum.find(digest.role_run_summaries, &(&1.key == :runtime))
    assert runtime.title == "Swarm packet"
    assert runtime.status == :waiting
    assert runtime.next_action =~ "one-time worker"
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
                "[delivery] What happened: implemented the feature. Files changed: feature modules. Evidence produced: code diff and focused test output. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the code diff, PR, and focused test output.",
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
    assert digest.receipt_audit.status == :ok

    assert digest.receipt_audit.present_fields == [
             "Action taken",
             "Evidence/artifact",
             "Verification",
             "Remaining risk",
             "Next decision",
             "Restart packet"
           ]

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
                "[delivery] What happened: implemented. Files changed: app. Evidence produced: code diff and test output. Verification: tests. Risks: low. Current state: ready. Next decision: review."
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
                "[delivery] What happened: implemented the feature. Files changed: feature modules. Evidence produced: code diff and focused test output. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review.",
              inserted_at: now
            },
            %Comment{
              author_type: "agent",
              author_id: cto_id,
              body:
                "[review] Verdict: accepted. What happened: verified the evidence. Evidence inspected: delivery work product and test output. Verification: tests passed. Gaps: none. Follow-up issues: none. Next decision: owner update.",
              inserted_at: DateTime.add(now, 2, :second)
            },
            %Comment{
              author_type: "agent",
              author_id: ceo_id,
              body:
                "[owner_update] What happened: owner-facing launch status is ready. Business status: not shipped. Evidence inspected: delivery artifact and CTO review. Current state: reviewed. Next decision: close. Owner decision needed: none.",
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

    blockers =
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

    assert Enum.map(blockers, & &1.key) == [:last_action_receipt, :delivery_comment]
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

  test "flags thin latest agent notes that miss the last-action receipt" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Thin receipt",
          status: :in_review,
          description: "Review a thin handoff.",
          comments: [
            %Comment{
              author_type: "agent",
              body:
                "[delivery] What happened: implemented the change. Files changed: app. Evidence produced: code diff. Verification: tests passed. Risks: none. Current state: ready. Next decision: CTO review.",
              inserted_at: DateTime.add(now, -2, :minute)
            },
            %Comment{
              author_type: "agent",
              body: "[handoff] Done.",
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

    assert digest.receipt_audit.status == :attention
    assert digest.receipt_audit.category == :handoff
    assert "Evidence/artifact" in digest.receipt_audit.missing_fields
    assert "Verification" in digest.receipt_audit.missing_fields
    assert "Remaining risk" in digest.receipt_audit.missing_fields
    assert "Restart packet" in digest.receipt_audit.missing_fields
    assert digest.receipt_audit.summary =~ "Latest handoff is missing"

    assert Enum.any?(
             digest.quality.gaps,
             &(&1.key == :last_action_receipt and &1.status == :attention)
           )

    assert Enum.any?(
             digest.review_readiness.blockers,
             &(&1.key == :last_action_receipt and
                 &1.prompt =~ "Latest handoff is missing receipt fields")
           )
  end

  test "audits the later list entry when agent comments share a timestamp" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    thin_receipt = %Comment{
      author_type: "agent",
      body: "[handoff] Done.",
      inserted_at: now
    }

    complete_receipt = %Comment{
      author_type: "agent",
      body:
        "[delivery] What happened: round two is ready. Files changed: lib/foo.ex. Evidence produced: code diff and test output. Verification: focused tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the diff and tests.",
      inserted_at: now
    }

    assert %{status: :ok, latest_comment: latest, summary: summary} =
             IssueDigest.audit_last_action_receipt([thin_receipt, complete_receipt])

    assert latest.category == :delivery
    assert latest.body =~ "round two is ready"
    assert summary =~ "complete last-action receipt"

    assert %{status: :attention, latest_comment: %{category: :handoff}} =
             IssueDigest.audit_last_action_receipt([complete_receipt, thin_receipt])
  end

  test "flags otherwise complete receipts without restart context" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    digest =
      IssueDigest.build(
        %Issue{
          title: "Needs restart packet",
          status: :in_review,
          description: "Review a delivery note without resume context.",
          comments: [
            %Comment{
              author_type: "agent",
              body:
                "[delivery] What happened: implemented the change. Files changed: app. Evidence produced: code diff. Verification: tests passed. Risks: none known. Next decision: CTO review.",
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

    assert digest.receipt_audit.status == :attention
    assert digest.receipt_audit.category == :delivery
    assert digest.receipt_audit.missing_fields == ["Restart packet"]

    assert Enum.any?(
             digest.review_readiness.blockers,
             &(&1.key == :last_action_receipt and
                 &1.prompt =~ "Restart packet")
           )
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
            "[delivery] What happened: child work completed. Files changed: child issue artifacts. Evidence produced: completed child artifacts and notes. Verification: checked completed child work. Risks: none known. Current state: ready for review. Next decision: CTO review.",
          inserted_at: DateTime.add(now, -2, :minute)
        },
        %Comment{
          author_type: "agent",
          body:
            "[review] Verdict: accepted. What happened: CTO reviewed the delegated work. Evidence inspected: closed child issues and delivery artifacts. Verification: child work is closed. Gaps: none. Follow-up issues: none. Next decision: CEO owner update.",
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

  test "delegated parent owner update satisfies closure packet without duplicate delivery tag" do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    issue = %Issue{
      title: "Delegated parent",
      status: :in_review,
      description: "Parent issue with completed child work.",
      comments: [
        %Comment{
          author_type: "agent",
          body:
            "[owner_update] What happened: delegated child work was reviewed and accepted. Business status: shipped. Evidence inspected: closed child issue and CTO review. Verification: child issue is done and owner update is complete. Remaining risk: none known. Current state: ready to close. Next decision: no further action. Owner decision needed: none. Restart packet: reopen only if the owner asks for follow-up.",
          inserted_at: now
        },
        %Comment{
          author_type: "system",
          body:
            "approve_issue rejected: Tagged `[delivery]` comment is missing required fields: What happened, Files changed, Evidence produced.",
          inserted_at: DateTime.add(now, 1, :second)
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
        [],
        [%Issue{status: :done, title: "Closed child"}]
      )

    refute Enum.any?(blockers, &(&1.key == :work_product))
    refute Enum.any?(blockers, &(&1.key == :delivery_comment))
    refute Enum.any?(blockers, &(&1.key == :ceo_owner_update))
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
                "[delivery] What happened: implemented the change. Files changed: feature modules. Evidence produced: code diff and focused test output. Verification: tests passed. Risks: none known. Current state: ready for review. Next decision: CTO review. Restart packet: CTO should inspect the code diff, PR, and focused test output.",
              inserted_at: DateTime.add(now, -2, :minute)
            },
            %Comment{
              author_type: "agent",
              body:
                "[review] Verdict: accepted. What happened: CTO verified the PR and tests. Evidence inspected: PR body, work product, and test output. Verification: tests passed. Gaps: none. Follow-up issues: none. Next decision: approval. Restart packet: CEO should inspect the accepted review, PR body, and test output before closing.",
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
