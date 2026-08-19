defmodule Cympho.CtoOrchestrationTest do
  @moduledoc """
  Regression cover for the CTO → engineering delegation path.

  The path has four seams — prompt, `delegate`, dispatch, recovery — and each
  one used to be able to drop delegated work silently. They compounded: an
  engineer stopped by governance kept `status: :idle` (only `governance_status`
  moves), so the CTO's prompt advertised it as the eligible idle candidate,
  `delegate` accepted it, dispatch ran it, no sweep looked at the resulting
  `:todo`, and the eventual stall escalated past the CTO to the CEO.
  """

  use Cympho.DataCase, async: false

  alias Cympho.AgentActions
  alias Cympho.AgentGovernance
  alias Cympho.AgentPrompt
  alias Cympho.Agents
  alias Cympho.Authentication
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Orchestrator.Dispatcher.State
  alias Cympho.Oversight.Patrol
  alias Cympho.Repo
  alias Cympho.Runtime
  alias Cympho.Wakes.AgentWake

  import Ecto.Query

  @delivery_brief "Acceptance criteria: the login route returns a session token. " <>
                    "Evidence required: pull request link. " <>
                    "Verification required: mix test test/auth_test.exs. " <>
                    "Definition of done: ready for review with passing tests."

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "CTO Orchestration Co #{unique}",
        slug: "cto-orch-#{unique}",
        issue_prefix: "CTO"
      })

    {:ok, ceo} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Chief",
        role: :ceo,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, cto} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Tech Chief",
        role: :cto,
        status: :idle,
        parent_id: ceo.id,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, engineer} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Engineer One",
        role: :engineer,
        status: :idle,
        parent_id: cto.id,
        adapter: :process,
        config: %{"command" => "echo", "repo_capable" => true}
      })

    %{company: company, ceo: ceo, cto: cto, engineer: engineer}
  end

  defp terminate(agent) do
    {:ok, terminated} =
      AgentGovernance.terminate_agent(
        agent.id,
        "no longer needed",
        [requires_board_approval: false],
        nil
      )

    terminated
  end

  defp create_issue!(attrs) do
    {:ok, issue} = Issues.create_issue(attrs)
    issue
  end

  defp backdate!(%Issue{} = issue, minutes) do
    at =
      DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

    {:ok, updated} = Repo.update(Ecto.Changeset.change(issue, %{updated_at: at}))
    updated
  end

  describe "governance_active?/1" do
    test "termination stops the agent without touching :status", %{engineer: engineer} do
      terminated = terminate(engineer)

      # The exact shape the rest of this file depends on: governance moved,
      # `status` did not. Any check written against `status` alone sees an
      # idle, available engineer.
      assert terminated.governance_status == "terminated"
      assert terminated.status == :idle

      refute Agents.governance_active?(terminated)
      assert Agents.governance_active?(engineer)
    end
  end

  describe "seam 1 — the CTO's team status block" do
    test "a governance-stopped engineer is not offered as eligible capacity", %{
      company: company,
      cto: cto,
      engineer: engineer
    } do
      terminate(engineer)

      issue =
        create_issue!(%{
          title: "Ship the auth rewrite",
          description: @delivery_brief,
          status: :in_progress,
          company_id: company.id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      prompt = AgentPrompt.build(issue, cto)
      line = engineer_status_line(prompt)

      # Before the fix this read "1 agents (1 idle, 0 working) ... eligible
      # idle: Engineer One (id: ..., load: 0/3)" and the staffing rule then
      # forbade spawning the replacement the role actually needed.
      refute line =~ "eligible idle"
      refute prompt =~ engineer.id
      assert line =~ "0 available agents"
      assert line =~ "1 stopped by governance"
      assert line =~ "no usable agents in role"
    end

    test "a live engineer is still offered", %{company: company, cto: cto, engineer: engineer} do
      issue =
        create_issue!(%{
          title: "Ship the auth rewrite",
          description: @delivery_brief,
          status: :in_progress,
          company_id: company.id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      line = cto |> then(&AgentPrompt.build(issue, &1)) |> engineer_status_line()

      assert line =~ "1 available agents"
      assert line =~ "eligible idle"
      assert line =~ engineer.id
      refute line =~ "stopped by governance"
    end

    defp engineer_status_line(prompt) do
      prompt
      |> String.split("\n")
      |> Enum.find("", &String.starts_with?(&1, "- engineer:"))
    end
  end

  describe "seam 2 — delegate" do
    test "delegating to a governance-stopped agent is rejected", %{
      company: company,
      cto: cto,
      engineer: engineer
    } do
      terminate(engineer)

      issue =
        create_issue!(%{
          title: "Ship the auth rewrite",
          description: @delivery_brief,
          status: :in_progress,
          company_id: company.id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      assert {:error, {:delegate_target_stopped, target_id, "terminated"}} =
               AgentActions.execute(issue, cto, [
                 %{
                   "type" => "delegate",
                   "to_agent_id" => engineer.id,
                   "reason" => @delivery_brief
                 }
               ])

      assert target_id == engineer.id

      # The issue must not have been handed over.
      reloaded = Repo.get!(Issue, issue.id)
      assert reloaded.assignee_id == cto.id

      # And the CTO must be able to see why on its next turn.
      assert AgentActions.retriable_contract_error?(
               {:delegate_target_stopped, engineer.id, "terminated"}
             )

      bodies = issue.id |> comment_bodies() |> Enum.join("\n")
      assert bodies =~ "delegate rejected"
      assert bodies =~ "terminated"
    end

    test "delegating to a live agent still works", %{
      company: company,
      cto: cto,
      engineer: engineer
    } do
      issue =
        create_issue!(%{
          title: "Ship the auth rewrite",
          description: @delivery_brief,
          status: :in_progress,
          company_id: company.id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      assert {:ok, _} =
               AgentActions.execute(issue, cto, [
                 %{
                   "type" => "delegate",
                   "to_agent_id" => engineer.id,
                   "reason" => @delivery_brief
                 }
               ])

      assert Repo.get!(Issue, issue.id).assignee_id == engineer.id
    end

    defp comment_bodies(issue_id) do
      from(c in Cympho.Comments.Comment, where: c.issue_id == ^issue_id, select: c.body)
      |> Repo.all()
    end
  end

  describe "seam 3 — dispatch" do
    test "the assigned-agent path refuses a governance-stopped assignee", %{
      company: company,
      engineer: engineer
    } do
      issue =
        create_issue!(%{
          title: "Implement the session store",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      # Live assignee resolves.
      assert {:ok, %{id: resolved}} = Dispatcher.preview_agent_for_issue(issue)
      assert resolved == engineer.id

      terminate(engineer)

      # `list_eligible_agents/2` already filtered governance on the routed
      # path; the explicit-assignee path did not, so a stopped agent kept
      # receiving every issue pinned to it.
      assert {:error, :no_agent_available} = Dispatcher.preview_agent_for_issue(issue)
    end

    test "runtime preflight refuses a governance-stopped agent", %{
      company: company,
      engineer: engineer
    } do
      issue =
        create_issue!(%{
          title: "Implement the session store",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      terminated = terminate(engineer)

      assert {:error, {:agent_governance_blocked, "terminated"}} =
               Runtime.dispatchable?(issue, terminated)

      # Not bypassable: `skip_agent_status?` relaxes the operational status for
      # an owned run, never a governance stop.
      assert {:error, {:agent_governance_blocked, "terminated"}} =
               Runtime.dispatchable?(issue, terminated, skip_agent_status?: true)
    end
  end

  describe "seam 4 — recovery" do
    test "termination rehomes the work it was holding", %{
      company: company,
      engineer: engineer
    } do
      in_flight =
        create_issue!(%{
          title: "Half-finished migration",
          description: @delivery_brief,
          status: :in_progress,
          company_id: company.id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      terminate(engineer)

      reloaded = Repo.get!(Issue, in_flight.id)

      # Pause has always rehomed; termination is the more permanent stop and
      # used to leave the whole queue pinned to a dead agent.
      assert reloaded.status == :todo
      refute reloaded.assignee_id == engineer.id
    end

    test "a :todo issue that never ran becomes visible to patrol", %{
      company: company,
      engineer: engineer
    } do
      stranded =
        %{
          title: "Delegated but never dispatched",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        }
        |> create_issue!()
        |> backdate!(300)

      stuck = Issues.list_stuck_issues(company.id)
      assert Enum.any?(stuck, &(&1.id == stranded.id))

      # Still bounded by its own threshold, and still disable-able.
      assert Issues.list_stuck_issues(company.id, todo_minutes: 0) == []
    end

    test "a fresh :todo issue is not stuck", %{company: company, engineer: engineer} do
      fresh =
        create_issue!(%{
          title: "Just delegated",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assignee_id: engineer.id,
          assigned_role: "engineer"
        })

      refute Enum.any?(Issues.list_stuck_issues(company.id), &(&1.id == fresh.id))
    end

    test "a stalled fan-out escalates to the CTO that parked it, not the CEO", %{
      company: company,
      ceo: ceo,
      cto: cto
    } do
      # Exactly the shape `maybe_auto_block_after_decomposition/3` leaves
      # behind: blocked, no assignee, decomposition owner recorded.
      parent =
        %{
          title: "Auth rewrite — parked after fan-out",
          description: @delivery_brief,
          status: :blocked,
          company_id: company.id,
          assigned_role: "cto",
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => cto.id
          }
        }
        |> create_issue!()
        |> backdate!(300)

      assert [%{issue: %{id: id}, supervisor: supervisor}] =
               Enum.filter(Patrol.preview_company(company.id), &(&1.issue.id == parent.id))

      assert id == parent.id
      assert supervisor.id == cto.id
      refute supervisor.id == ceo.id
    end

    test "an unassigned child escalates to its parent issue's owner", %{
      company: company,
      ceo: ceo,
      cto: cto
    } do
      parent =
        create_issue!(%{
          title: "Auth rewrite",
          description: @delivery_brief,
          status: :blocked,
          company_id: company.id,
          assignee_id: cto.id,
          assigned_role: "cto"
        })

      child =
        %{
          title: "Session store",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          parent_id: parent.id,
          assigned_role: "engineer"
        }
        |> create_issue!()
        |> backdate!(300)

      entry = Enum.find(Patrol.preview_company(company.id), &(&1.issue.id == child.id))

      assert entry.supervisor.id == cto.id
      refute entry.supervisor.id == ceo.id
    end

    test "a stopped decomposition owner still falls back to the CEO", %{
      company: company,
      ceo: ceo,
      cto: cto
    } do
      parent =
        %{
          title: "Auth rewrite — owner since terminated",
          description: @delivery_brief,
          status: :blocked,
          company_id: company.id,
          assigned_role: "cto",
          monitor_state: %{"decomposition_owner_id" => cto.id}
        }
        |> create_issue!()
        |> backdate!(300)

      terminate(cto)

      entry = Enum.find(Patrol.preview_company(company.id), &(&1.issue.id == parent.id))
      assert entry.supervisor.id == ceo.id
    end
  end

  describe "staffing escalation" do
    test "an engineering gap wakes the CTO", %{company: company, cto: cto, ceo: ceo} do
      issue =
        create_issue!(%{
          title: "Nobody can take this",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assigned_role: "engineer"
        })

      Dispatcher.record_dispatch_failure(issue, State.new(), :no_agent)

      assert [%AgentWake{agent_id: agent_id, reason: "no_agent_for_role"}] =
               no_agent_wakes(issue.id)

      assert agent_id == cto.id
      refute agent_id == ceo.id
    end

    test "a non-engineering gap still wakes the CEO", %{company: company, ceo: ceo} do
      issue =
        create_issue!(%{
          title: "Nobody can take this either",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assigned_role: "designer"
        })

      Dispatcher.record_dispatch_failure(issue, State.new(), :no_agent)

      assert [%AgentWake{agent_id: agent_id}] = no_agent_wakes(issue.id)
      assert agent_id == ceo.id
    end

    test "an engineering gap falls back to the CEO when there is no CTO", %{
      company: company,
      cto: cto,
      ceo: ceo
    } do
      terminate(cto)

      issue =
        create_issue!(%{
          title: "Nobody can take this at all",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assigned_role: "engineer"
        })

      Dispatcher.record_dispatch_failure(issue, State.new(), :no_agent)

      assert [%AgentWake{agent_id: agent_id}] = no_agent_wakes(issue.id)
      assert agent_id == ceo.id
    end

    test "the CTO is told it can staff the gap itself", %{company: company, cto: cto} do
      issue =
        create_issue!(%{
          title: "Nobody can take this",
          description: @delivery_brief,
          status: :todo,
          company_id: company.id,
          assigned_role: "engineer"
        })

      prompt =
        AgentPrompt.build(issue, cto,
          wake_context: {"no_agent_for_role", %{"missing_role" => "engineer"}}
        )

      # The old text ("only the CEO can hire new agents") contradicted the
      # CTO's own spawn_agent contract and wasted the turn it was woken for.
      assert prompt =~ "you own staffing for that lane"
      assert prompt =~ "spawn_agent"
      refute prompt =~ "only the CEO can hire new agents"
    end

    defp no_agent_wakes(issue_id) do
      from(w in AgentWake,
        where: w.issue_id == ^issue_id and w.reason == "no_agent_for_role"
      )
      |> Repo.all()
    end
  end

  describe "governance API defaults" do
    test "pause_agent/2 pauses instead of raising", %{engineer: engineer} do
      # Two bugs stacked here. `opts \\ %{}` fed straight into `Keyword.get/3`,
      # so every call relying on the default raised FunctionClauseError; past
      # that, `paused_at` was stamped untruncated into a `:utc_datetime`
      # column, so the update raised on dump.
      assert {:ok, paused} = AgentGovernance.pause_agent(engineer.id, nil)

      assert paused.governance_status == "paused"
      assert paused.status == :paused
      assert %DateTime{microsecond: {0, 0}} = paused.paused_at
      refute Agents.governance_active?(paused)
    end

    test "termination revokes every active API key", %{engineer: engineer} do
      {:ok, {_first_key, first_token}} =
        Authentication.create_agent_api_key(engineer.id, "First key")

      {:ok, {_second_key, second_token}} =
        Authentication.create_agent_api_key(engineer.id, "Second key")

      terminate(engineer)

      revoked = Authentication.list_agent_api_keys(engineer.id)
      assert length(revoked) == 2
      assert Enum.all?(revoked, &match?(%DateTime{}, &1.expires_at))
      assert {:error, :invalid_api_key} = Authentication.validate_api_key(first_token)
      assert {:error, :invalid_api_key} = Authentication.validate_api_key(second_token)
    end

    test "pause preserves a key but blocks it until governance resumes the agent", %{
      engineer: engineer
    } do
      {:ok, {api_key, token}} = Authentication.create_agent_api_key(engineer.id, "Resume key")

      assert {:ok, paused} = AgentGovernance.pause_agent(engineer.id, nil)
      assert {:error, :invalid_api_key} = Authentication.validate_api_key(token)
      assert is_nil(Authentication.get_agent_api_key(api_key.id).expires_at)

      assert {:ok, resumed} = AgentGovernance.resume_agent(paused.id, "Ready again", nil)
      assert resumed.status == :idle
      assert resumed.governance_status == "active"
      assert {:ok, authenticated} = Authentication.validate_api_key(token)
      assert authenticated.id == engineer.id
    end

    test "direct runtime termination also revokes active API keys", %{engineer: engineer} do
      {:ok, {_api_key, token}} = Authentication.create_agent_api_key(engineer.id, "Runtime key")

      assert {:ok, terminated} = Agents.terminate_agent(engineer)
      assert terminated.status == :terminated
      assert {:error, :invalid_api_key} = Authentication.validate_api_key(token)
    end
  end
end
