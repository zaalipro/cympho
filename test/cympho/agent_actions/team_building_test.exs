defmodule Cympho.AgentActions.TeamBuildingTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Companies, Issues, Wakes}
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: seed_issues
     }} =
      Companies.create_autonomous_company(%{
        name: "Team Build Co #{System.unique_integer([:positive])}",
        issue_prefix: "TBC",
        engineer_count: 1
      })

    issue = List.first(seed_issues)
    {:ok, issue} = Issues.checkout_issue(issue, ceo, :ceo)

    %{
      company: company,
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      issue: issue
    }
  end

  describe "spawn_agent" do
    setup [:start_heartbeat_supervisor]

    test "CEO can hire a new engineer", %{ceo: ceo, issue: issue} do
      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Engineer Two",
          "role" => "engineer"
        }
      ]

      assert {:ok, %{results: [%{type: "spawn_agent", agent_id: new_id, role: "engineer"}]}} =
               AgentActions.execute(issue, ceo, actions)

      {:ok, hired} = Agents.get_agent(new_id)
      assert hired.role == :engineer
      assert hired.parent_id == ceo.id
      assert hired.company_id == ceo.company_id

      Cympho.AgentHeartbeat.stop_for_agent(new_id)
    end

    test "engineer cannot spawn an agent", %{engineer: engineer, issue: issue} do
      # Re-checkout the issue to the engineer to satisfy unresolved_current_issue?
      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, eng_issue} = Issues.checkout_issue(issue, engineer, :engineer)

      actions = [
        %{"type" => "spawn_agent", "name" => "Sneak", "role" => "engineer"}
      ]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(eng_issue, engineer, actions)
    end

    test "CTO cannot spawn a CEO (rank violation)", %{cto: cto, issue: issue} do
      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, cto_issue} = Issues.checkout_issue(issue, cto, :cto)

      actions = [
        %{"type" => "spawn_agent", "name" => "Coup", "role" => "ceo"}
      ]

      assert {:error, :unauthorized_spawn} =
               AgentActions.execute(cto_issue, cto, actions)
    end
  end

  describe "delegate" do
    test "CEO can delegate an issue to an engineer", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      actions = [
        %{
          "type" => "delegate",
          "to_agent_id" => engineer.id,
          "reason" => "You wrote that module last week."
        }
      ]

      assert {:ok, %{results: [%{type: "delegate", to_agent_id: target}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert target == engineer.id

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == engineer.id
      assert reloaded.assigned_role == "engineer"
      assert reloaded.status == :todo

      [wake] = pending_wakes(engineer.id, "manager_directive")
      assert wake.metadata["reason"] =~ "module last week"
      assert wake.metadata["from_agent_id"] == ceo.id
    end

    test "engineer cannot delegate (governance role required)", %{
      engineer: engineer,
      cto: cto,
      issue: issue
    } do
      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, eng_issue} = Issues.checkout_issue(issue, engineer, :engineer)

      actions = [
        %{"type" => "delegate", "to_agent_id" => cto.id, "reason" => "you do it"}
      ]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(eng_issue, engineer, actions)
    end

    test "rejects equal-rank delegation", %{ceo: ceo, issue: issue} do
      # Create a peer CEO (rank 5 = rank 5, not strictly outranked).
      {:ok, peer_ceo} =
        Agents.create_agent(%{
          name: "Peer CEO",
          role: :ceo,
          status: :idle,
          company_id: ceo.company_id
        })

      actions = [
        %{"type" => "delegate", "to_agent_id" => peer_ceo.id, "reason" => "share work"}
      ]

      assert {:error, :delegate_rank_violation} =
               AgentActions.execute(issue, ceo, actions)
    end
  end

  describe "escalate" do
    test "engineer escalation blocks issue and wakes parent", %{
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      # Set CTO as engineer's parent so the escalation has a target.
      {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: cto.id})

      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, eng_issue} = Issues.checkout_issue(issue, engineer, :engineer)

      actions = [
        %{
          "type" => "escalate",
          "reason" => "Spec conflicts with itself, need human-level call.",
          "to_role" => "cto"
        }
      ]

      assert {:ok, %{results: [%{type: "escalate", to_agent_id: target}]}} =
               AgentActions.execute(eng_issue, engineer, actions)

      assert target == cto.id

      reloaded = Issues.get_issue!(eng_issue.id)
      assert reloaded.status == :blocked
      assert reloaded.assigned_role == "cto"
      assert reloaded.assignee_id == cto.id

      [wake] = pending_wakes(cto.id, "escalation_from_subordinate")
      assert wake.metadata["from_agent_id"] == engineer.id
      assert wake.metadata["reason"] =~ "Spec conflicts"

      # CEO is unaffected.
      assert pending_wakes(ceo.id, "escalation_from_subordinate") == []
    end

    test "CEO cannot escalate (no supervisor)", %{ceo: ceo, issue: issue} do
      actions = [%{"type" => "escalate", "reason" => "give up"}]

      assert {:error, :no_supervisor_to_escalate} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "engineer with no parent escalates to company CEO", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: nil})

      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, eng_issue} = Issues.checkout_issue(issue, engineer, :engineer)

      actions = [%{"type" => "escalate", "reason" => "no parent"}]

      assert {:ok, %{results: [%{type: "escalate", to_agent_id: target}]}} =
               AgentActions.execute(eng_issue, engineer, actions)

      assert target == ceo.id
    end
  end

  describe "Wakes helpers" do
    test "wake_for_escalation persists with the right reason", %{cto: cto, issue: issue} do
      assert {:ok, wake} =
               Wakes.wake_for_escalation(cto.id, issue.id, %{
                 "from_agent_id" => "abc",
                 "reason" => "test"
               })

      assert wake.reason == "escalation_from_subordinate"
      assert wake.metadata["reason"] == "test"
    end

    test "wake_for_manager_directive persists with the right reason", %{
      engineer: engineer,
      issue: issue
    } do
      assert {:ok, wake} =
               Wakes.wake_for_manager_directive(engineer.id, issue.id, %{
                 "from_agent_id" => "abc"
               })

      assert wake.reason == "manager_directive"
    end

    test "wake_for_no_agent_for_role persists with the right reason", %{ceo: ceo, issue: issue} do
      assert {:ok, wake} =
               Wakes.wake_for_no_agent_for_role(ceo.id, issue.id, %{
                 "missing_role" => "engineer"
               })

      assert wake.reason == "no_agent_for_role"
      assert wake.metadata["missing_role"] == "engineer"
    end
  end

  ## helpers

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end

  defp start_heartbeat_supervisor(_context) do
    case start_supervised({Cympho.AgentHeartbeat.Supervisor, []}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    case start_supervised({Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry}) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :ok
  end
end
