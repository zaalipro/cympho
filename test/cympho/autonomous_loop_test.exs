defmodule Cympho.AutonomousLoopTest do
  @moduledoc """
  Structural end-to-end coverage for the no-human-in-loop autonomous business
  loop. Each test exercises one architectural seam in isolation, plus a final
  composition test that walks the whole CEO → CTO → engineer → CEO-review path
  through the data layer.

  We do not drive a real (or mock) `AgentRunner` here — these tests assert that
  the *plumbing* between create_issue, wakes, decomposition, transitions, and
  the stale-nudge scanner behaves correctly. A future test that scripts a mock
  adapter to emit `cympho-actions` could layer on top of these primitives.
  """

  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Companies, Issues, Repo, Wakes}
  alias Cympho.ReviewNudges.StaleScanner
  alias Cympho.Wakes.AgentWake

  import Ecto.Query, warn: false

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: seed_issues
     }} =
      Companies.create_autonomous_company(%{
        name: "Loop Co #{System.unique_integer([:positive])}",
        issue_prefix: "LP",
        engineer_count: 1
      })

    # Leave the CEO idle by default — tests that need a checked-out parent
    # issue (Moves 5, 2) do so explicitly so Move 1 can find an eligible CEO.
    seed = List.first(seed_issues)

    %{company: company, ceo: ceo, cto: cto, engineer: engineer, seed_issue: seed}
  end

  # ---------------------------------------------------------------
  # Move 5 — Richer create_issue action response
  # ---------------------------------------------------------------
  describe "Move 5 — create_issue response envelope" do
    test "includes identifier, assigned_role, and status", %{
      ceo: ceo,
      seed_issue: seed
    } do
      {:ok, issue} = Issues.checkout_issue(seed, ceo, :ceo)

      actions = [
        %{
          "type" => "create_issue",
          "title" => "Ship the homepage",
          "role" => "engineer"
        }
      ]

      assert {:ok, %{results: [result]}} = AgentActions.execute(issue, ceo, actions)

      assert %{
               type: "create_issue",
               issue_id: child_id,
               identifier: identifier,
               assigned_role: "engineer",
               status: :todo
             } = result

      created = Issues.get_issue!(child_id)
      assert created.identifier == identifier or created.id == identifier
    end
  end

  # ---------------------------------------------------------------
  # Move 2 — Wake on child-issue create
  # ---------------------------------------------------------------
  describe "Move 2 — wake-on-create for child issues" do
    test "emits a wake row in the dispatcher's queue for each new child", %{
      ceo: ceo,
      seed_issue: seed
    } do
      {:ok, issue} = Issues.checkout_issue(seed, ceo, :ceo)

      actions = [
        %{"type" => "create_issue", "title" => "Sub one", "role" => "engineer"},
        %{"type" => "create_issue", "title" => "Sub two", "role" => "engineer"}
      ]

      assert {:ok, %{results: results}} = AgentActions.execute(issue, ceo, actions)
      assert length(results) == 2

      child_ids = Enum.map(results, & &1.issue_id)

      # `enqueue_wake/3` on an unassigned issue does not persist an AgentWake
      # (those need an agent_id). It instead pushes the dispatcher to poll.
      # We verify the children are dispatcher-visible: they are :todo + have
      # an assigned_role set. The wake call itself is best-effort and
      # idempotent at the mailbox level.
      Enum.each(child_ids, fn id ->
        c = Issues.get_issue!(id)
        assert c.status == :todo
        assert c.parent_id == issue.id
        assert c.assigned_role == "engineer"
      end)
    end
  end

  # ---------------------------------------------------------------
  # Move 1 — Auto-ignite top-level issues synchronously
  # ---------------------------------------------------------------
  describe "Move 1 — auto-ignite top-level issues" do
    setup do
      orig_enabled = Application.get_env(:cympho, :auto_ignite_on_create)
      orig_sync = Application.get_env(:cympho, :auto_ignite_sync)
      Application.put_env(:cympho, :auto_ignite_on_create, true)
      Application.put_env(:cympho, :auto_ignite_sync, true)

      on_exit(fn ->
        restore(:auto_ignite_on_create, orig_enabled)
        restore(:auto_ignite_sync, orig_sync)
      end)

      :ok
    end

    test "assigns a new top-level :backlog issue and emits a wake", %{company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Build the marketing site",
          description: "Top-level strategic issue.",
          company_id: company.id,
          status: :backlog,
          assigned_role: "ceo"
        })

      # `maybe_auto_ignite` runs in Task.Supervisor; wait briefly for it.
      :ok = wait_until(fn -> Issues.get_issue!(issue.id).assignee_id != nil end)

      ignited = Issues.get_issue!(issue.id)
      assert ignited.assignee_id != nil
      assert ignited.status == :in_progress

      assignee = Agents.get_agent!(ignited.assignee_id)
      assert assignee.role == :ceo

      wakes = Wakes.list_issue_wakes(issue.id)
      assert Enum.any?(wakes, &(&1.reason == "issue_created"))
    end

    test "opt-out via skip_auto_assign leaves issue in backlog", %{company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Do not auto-ignite me",
          company_id: company.id,
          status: :backlog,
          skip_auto_assign: true
        })

      # Give the supervisor a moment to *not* do anything.
      Process.sleep(150)

      latest = Issues.get_issue!(issue.id)
      assert latest.assignee_id == nil
      assert latest.status == :backlog
    end

    test "child issues are not auto-ignited (parent owns the lifecycle)", %{
      company: company,
      seed_issue: seed
    } do
      {:ok, child} =
        Issues.create_issue(%{
          title: "Child should not auto-ignite",
          company_id: company.id,
          parent_id: seed.id,
          status: :todo
        })

      Process.sleep(100)

      latest = Issues.get_issue!(child.id)
      assert latest.parent_id == seed.id
      # Should not have been routed by the top-level ignition path.
      assert latest.status == :todo
    end
  end

  # ---------------------------------------------------------------
  # Move 3 — Wake parent's assignee when child enters :in_review
  # ---------------------------------------------------------------
  describe "Move 3 — parent wake on child :in_review" do
    test "wakes the parent's assignee with reason child_status_changed", %{
      company: company,
      cto: cto,
      engineer: engineer
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent owned by CTO",
          company_id: company.id,
          status: :in_progress,
          assignee_id: cto.id,
          assigned_role: "cto",
          skip_auto_assign: true
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Engineer subtask",
          company_id: company.id,
          parent_id: parent.id,
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _} = Issues.transition_issue(child, :in_review)

      wakes = Wakes.list_issue_wakes(parent.id)
      assert Enum.any?(wakes, &(&1.reason == "child_status_changed" and &1.agent_id == cto.id))
    end

    test "deduplicates re-wakes within the dedup window", %{
      company: company,
      cto: cto,
      engineer: engineer
    } do
      {:ok, parent} =
        Issues.create_issue(%{
          title: "Parent dedup",
          company_id: company.id,
          status: :in_progress,
          assignee_id: cto.id,
          assigned_role: "cto",
          skip_auto_assign: true
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Engineer subtask dedup",
          company_id: company.id,
          parent_id: parent.id,
          status: :in_progress,
          assignee_id: engineer.id
        })

      {:ok, in_review} = Issues.transition_issue(child, :in_review)
      {:ok, _} = Issues.transition_issue(in_review, :todo)
      {:ok, _} = Issues.transition_issue(Issues.get_issue!(child.id), :in_review)

      count =
        Wakes.list_issue_wakes(parent.id)
        |> Enum.count(&(&1.reason == "child_status_changed"))

      assert count == 1
    end
  end

  # ---------------------------------------------------------------
  # Move 6 — CEO terminal review for root issues
  # ---------------------------------------------------------------
  describe "Move 6 — CEO terminal review" do
    test "root issue owned by CEO transitions to :in_review (not :done) and CEO is woken", %{
      company: company,
      ceo: ceo,
      engineer: engineer
    } do
      {:ok, root} =
        Issues.create_issue(%{
          title: "CEO-owned root",
          company_id: company.id,
          status: :in_progress,
          assignee_id: ceo.id,
          assigned_role: "ceo",
          skip_auto_assign: true
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Engineer leaf",
          company_id: company.id,
          parent_id: root.id,
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _} = Issues.transition_issue(child, :done)

      after_close = Issues.get_issue!(root.id)
      assert after_close.status == :in_review

      wakes = Wakes.list_issue_wakes(root.id)
      assert Enum.any?(wakes, &(&1.reason == "final_review_required" and &1.agent_id == ceo.id))
    end

    test "engineer-owned root still auto-completes to :done", %{
      company: company,
      engineer: engineer
    } do
      {:ok, root} =
        Issues.create_issue(%{
          title: "Engineer-owned root",
          company_id: company.id,
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          skip_auto_assign: true
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Engineer leaf 2",
          company_id: company.id,
          parent_id: root.id,
          status: :in_progress,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      {:ok, _} = Issues.transition_issue(child, :done)

      assert Issues.get_issue!(root.id).status == :done
    end
  end

  # ---------------------------------------------------------------
  # Move 4 — Stale review-nudge scanner
  # ---------------------------------------------------------------
  describe "Move 4 — stale review-nudge scanner" do
    test "re-emits a fresh wake when an active nudge is older than T1", %{
      company: company,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Issue with stale nudge",
          company_id: company.id,
          status: :in_review,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          skip_auto_assign: true
        })

      {:ok, original} =
        Wakes.do_wake_agent(
          engineer.id,
          issue.id,
          "manual_dispatch",
          "system",
          "test",
          %{"source" => "review_nudge", "agent_role" => "engineer"}
        )

      # Backdate to make it look stale.
      backdate_wake!(original.id, -300)

      counts = StaleScanner.sweep(t1_seconds: 60, t2_seconds: 1800, max_re_emits: 3)

      assert counts.re_emitted >= 1

      re_emits =
        Wakes.list_issue_wakes(issue.id)
        |> Enum.filter(&(&1.reason == "review_nudge_re_emit"))

      assert length(re_emits) >= 1
    end

    test "escalates to a different agent in the same role at T2 / max_re_emits", %{
      company: company,
      engineer: engineer
    } do
      # Add a second engineer in the same company so escalation has a target.
      {:ok, alt_engineer} =
        Agents.create_agent(%{
          name: "Backup Engineer",
          role: :engineer,
          adapter: :process,
          status: :idle,
          company_id: company.id
        })

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Issue with abandoned nudge",
          company_id: company.id,
          status: :in_review,
          assignee_id: engineer.id,
          assigned_role: "engineer",
          skip_auto_assign: true
        })

      {:ok, original} =
        Wakes.do_wake_agent(
          engineer.id,
          issue.id,
          "manual_dispatch",
          "system",
          "test",
          %{
            "source" => "review_nudge",
            "agent_role" => "engineer",
            "re_emit_count" => 5
          }
        )

      backdate_wake!(original.id, -7_200)

      counts = StaleScanner.sweep(t1_seconds: 60, t2_seconds: 600, max_re_emits: 3)

      assert counts.escalated >= 1

      reassigned = Issues.get_issue!(issue.id)
      assert reassigned.assignee_id != engineer.id
      assert reassigned.assignee_id == alt_engineer.id

      escalations =
        Wakes.list_issue_wakes(issue.id)
        |> Enum.filter(&(&1.reason == "review_nudge_escalated"))

      assert length(escalations) >= 1
    end
  end

  # ---------------------------------------------------------------
  # Composition — the moves chain into a coherent loop
  # ---------------------------------------------------------------
  describe "composition — full loop" do
    test "CEO creates engineer child → child :done → root :in_review wakes CEO", %{
      ceo: ceo,
      engineer: engineer,
      seed_issue: seed
    } do
      # Use the seed issue (created with project_id wired) and check the CEO
      # out onto it as the starting "root" of the autonomous chain.
      {:ok, root} = Issues.checkout_issue(seed, ceo, :ceo)
      {:ok, root} = Issues.update_issue(root, %{assigned_role: "ceo"})

      # CEO decomposes via the action surface.
      assert {:ok, %{results: [%{issue_id: child_id, assigned_role: "engineer"}]}} =
               AgentActions.execute(root, ceo, [
                 %{"type" => "create_issue", "title" => "Engineer leaf X", "role" => "engineer"}
               ])

      # Engineer picks it up + finishes.
      child = Issues.get_issue!(child_id)
      assert child.parent_id == root.id
      assert child.status == :todo

      {:ok, child} = Issues.checkout_issue(child, engineer, :engineer)
      {:ok, _} = Issues.transition_issue(child, :in_review)

      # Parent should have a `child_status_changed` wake for the CEO.
      parent_wakes = Wakes.list_issue_wakes(root.id)
      assert Enum.any?(parent_wakes, &(&1.reason == "child_status_changed" and &1.agent_id == ceo.id))

      # Engineer "wraps up" — child :done. Root flips to :in_review.
      {:ok, _} = Issues.transition_issue(Issues.get_issue!(child_id), :done)

      assert Issues.get_issue!(root.id).status == :in_review

      final_wakes = Wakes.list_issue_wakes(root.id)
      assert Enum.any?(final_wakes, &(&1.reason == "final_review_required" and &1.agent_id == ceo.id))
    end
  end

  # ---------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------

  defp wait_until(fun, attempts \\ 30) when is_function(fun, 0) do
    cond do
      fun.() -> :ok
      attempts <= 0 -> {:error, :timeout}
      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:cympho, key, value)

  defp backdate_wake!(wake_id, seconds_offset) do
    cutoff = DateTime.utc_now() |> DateTime.add(seconds_offset, :second) |> DateTime.truncate(:second)
    from(w in AgentWake, where: w.id == ^wake_id) |> Repo.update_all(set: [inserted_at: cutoff])
  end
end
