defmodule Cympho.Oversight.PatrolTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Companies, Issues}
  alias Cympho.Oversight.Patrol
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: [issue | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Patrol Co #{System.unique_integer([:positive])}",
        issue_prefix: "PAT",
        engineer_count: 1
      })

    # Engineer's parent must be the CTO so the routing logic finds them.
    {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: cto.id})

    %{company: company, ceo: ceo, cto: cto, engineer: engineer, issue: issue}
  end

  describe "Issues.list_stuck_issues/2" do
    test "finds in_progress issues older than threshold", %{
      company: company,
      issue: issue,
      engineer: engineer
    } do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, _stale} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: engineer.id,
          checked_out_at: stale_at,
          updated_at: stale_at
        })

      stuck = Issues.list_stuck_issues(company.id, in_progress_minutes: 60)
      assert Enum.any?(stuck, &(&1.id == issue.id))
    end

    test "ignores fresh in_progress issues", %{
      company: company,
      issue: issue,
      engineer: engineer
    } do
      {:ok, _} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: engineer.id,
          checked_out_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stuck = Issues.list_stuck_issues(company.id, in_progress_minutes: 60)
      refute Enum.any?(stuck, &(&1.id == issue.id))
    end

    test "excludes synthetic backlog_planner issues", %{company: company} do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, planning} =
        Issues.create_issue(%{
          title: "Mission Planning",
          status: :in_progress,
          company_id: company.id,
          origin_type: "backlog_planner",
          checked_out_at: stale_at
        })

      stuck = Issues.list_stuck_issues(company.id, in_progress_minutes: 60)
      refute Enum.any?(stuck, &(&1.id == planning.id))
    end
  end

  describe "patrol_company/2" do
    test "wakes the engineer's parent (CTO) for stalled in_progress work", %{
      company: company,
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: engineer.id,
          checked_out_at: stale_at,
          updated_at: stale_at
        })

      assert %{stuck_found: 1, waked: 1} =
               Patrol.patrol_company(company.id,
                 in_progress_minutes: 60,
                 cooldown_seconds: 0
               )

      [wake] = pending_wakes(cto.id, "issue_stalled_in_progress")
      assert wake.issue_id == issue.id
      assert wake.metadata["stuck_status"] == "in_progress"
    end

    test "respects cooldown — second sweep no-ops", %{
      company: company,
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: engineer.id,
          checked_out_at: stale_at,
          updated_at: stale_at
        })

      assert %{waked: 1} =
               Patrol.patrol_company(company.id,
                 in_progress_minutes: 60,
                 cooldown_seconds: 600
               )

      counters =
        Patrol.patrol_company(company.id, in_progress_minutes: 60, cooldown_seconds: 600)

      assert counters[:skipped_cooldown] == 1
      # `waked` key is only set when at least one wake fired this sweep.
      # Cooldown-only sweeps simply don't include it.
      assert Map.get(counters, :waked, 0) == 0

      # Only one wake total across both sweeps.
      assert pending_wakes(cto.id, "issue_stalled_in_progress") |> length() == 1
    end

    test "in_review stalled issue wakes the reviewer (current assignee)", %{
      company: company,
      cto: cto,
      issue: issue
    } do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      # Two-step: change status/assignee through the normal path, then bump
      # updated_at directly via Repo.update_all so the changeset's timestamp
      # auto-bump can't reset it.
      {:ok, _} =
        Issues.update_issue(issue, %{status: :in_review, assignee_id: cto.id})

      from(i in Cympho.Issues.Issue, where: i.id == ^issue.id)
      |> Repo.update_all(set: [updated_at: stale_at])

      assert %{waked: 1} =
               Patrol.patrol_company(company.id, in_review_minutes: 30, cooldown_seconds: 0)

      [wake] = pending_wakes(cto.id, "issue_stalled_in_progress")
      assert wake.issue_id == issue.id
    end

    test "no supervisor → counts as skipped_no_supervisor", %{
      company: company,
      ceo: ceo,
      issue: issue
    } do
      # Mark the CEO terminated so `get_company_ceo` can't find one.
      # (We can't simply delete the CEO because other agents reference her
      # via created_by_agent_id; agents.get_company_ceo filters terminated.)
      stale_at =
        DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, _} =
        Issues.update_issue(issue, %{
          status: :in_progress,
          assignee_id: nil,
          checked_out_at: stale_at,
          updated_at: stale_at
        })

      # governance_status is managed by the governance flow (Ecto.Changeset.change),
      # not request-driven updates — Agents.update_agent no longer mass-assigns it.
      {:ok, _} = ceo |> Ecto.Changeset.change(%{governance_status: "terminated"}) |> Repo.update()

      counters = Patrol.patrol_company(company.id, in_progress_minutes: 60, cooldown_seconds: 0)
      assert Map.get(counters, :skipped_no_supervisor, 0) >= 1
    end
  end

  ## helpers

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end
end
