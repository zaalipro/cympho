defmodule Cympho.AgentActions.TeamBuildingTest do
  use Cympho.DataCase, async: false

  alias Cympho.{AgentActions, Agents, Comments, Companies, Issues, Wakes}
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

    test "CEO must use an eligible idle engineer before hiring a duplicate", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Duplicate Engineer",
          "role" => "engineer"
        }
      ]

      assert {:error, {:spawn_agent_existing_capacity, :engineer, candidates}} =
               AgentActions.execute(issue, ceo, actions)

      assert candidates =~ engineer.name

      comments = Comments.list_comments(issue.id)
      assert Enum.any?(comments, &(&1.body =~ "spawn_agent rejected"))
      assert Enum.any?(comments, &(&1.body =~ "Use delegate, create_issue, or handoff"))
      assert Enum.any?(comments, &(&1.body =~ engineer.name))

      refute Enum.any?(
               Agents.list_agents_by_role(:engineer, ceo.company_id),
               &(&1.name == "Duplicate Engineer")
             )
    end

    test "CEO can hire a new engineer when existing engineers are at capacity", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      {:ok, _active} = saturate_agent(engineer)

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

    test "repo-delivery hires from a chat-only parent default to a repo-capable runtime profile",
         %{
           ceo: ceo,
           engineer: engineer,
           issue: issue
         } do
      {:ok, _active} = saturate_agent(engineer)

      original_default = Application.get_env(:cympho, :default_adapter)
      Application.put_env(:cympho, :default_adapter, :openai_chat)

      on_exit(fn ->
        if is_nil(original_default) do
          Application.delete_env(:cympho, :default_adapter)
        else
          Application.put_env(:cympho, :default_adapter, original_default)
        end
      end)

      {:ok, chat_ceo} = Agents.update_agent(ceo, %{adapter: :openai_chat})

      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Repo Engineer",
          "role" => "engineer"
        }
      ]

      assert {:ok, %{results: [%{type: "spawn_agent", agent_id: new_id, role: "engineer"}]}} =
               AgentActions.execute(issue, chat_ceo, actions)

      {:ok, hired} = Agents.get_agent(new_id)
      assert hired.adapter == :process
      assert hired.config["process_preset"] == "codex"
      assert hired.config["command"] == "codex"
      assert hired.runtime_config["profile_id"] == "process-codex"
      assert Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(hired)

      Cympho.AgentHeartbeat.stop_for_agent(new_id)
    end

    test "repo-delivery hire ignores text-only engineers and wakes waiting repo work",
         %{
           company: company,
           ceo: ceo,
           engineer: engineer,
           issue: issue
         } do
      {:ok, _chat_engineer} = Agents.update_agent(engineer, %{adapter: :openai_chat})

      {:ok, queued_issue} =
        Issues.create_issue(%{
          title: "Implement queued repo work",
          description: """
          Acceptance criteria: scoped repository change is implemented.
          Evidence required: PR or work product plus delivery note.
          Verification required: run a focused test.
          Definition of done: ready for CTO review.
          """,
          status: :todo,
          priority: :high,
          assigned_role: "engineer",
          company_id: company.id
        })

      assert is_nil(queued_issue.assignee_id)

      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Repo Lane Engineer",
          "role" => "engineer"
        }
      ]

      assert {:ok,
              %{
                results: [
                  %{
                    type: "spawn_agent",
                    agent_id: new_id,
                    role: "engineer",
                    assigned_count: 1,
                    wake_count: 1,
                    assigned_issue_ids: [assigned_issue_id]
                  }
                ]
              }} = AgentActions.execute(issue, ceo, actions)

      assert assigned_issue_id == queued_issue.id

      {:ok, hired} = Agents.get_agent(new_id)
      assert Cympho.AgentRuntimeCapabilities.repo_delivery_capable?(hired)

      reloaded_issue = Issues.get_issue!(queued_issue.id)
      assert reloaded_issue.assignee_id == new_id
      assert reloaded_issue.assigned_role == "engineer"
      assert reloaded_issue.status == :todo

      [wake] = Wakes.list_issue_wakes(queued_issue.id)
      assert wake.agent_id == new_id
      assert wake.reason == "manual_dispatch"
      assert wake.status == "pending"
      assert wake.metadata["source"] == "demand_backed_hire"
      assert wake.metadata["role"] == "engineer"
      assert wake.metadata["agent_id"] == new_id

      comments = Comments.list_comments(issue.id)
      assert Enum.any?(comments, &(&1.body =~ "Assigned 1 waiting issue"))
      assert Enum.any?(comments, &(&1.body =~ "queued 1 wake"))

      child_comments = Comments.list_comments(queued_issue.id)
      assert Enum.any?(child_comments, &(&1.body =~ "[handoff] Demand-backed hire assigned"))
      assert Enum.any?(child_comments, &(&1.body =~ "Repo Lane Engineer"))

      assert Enum.any?(
               child_comments,
               &(&1.body =~ "queued engineer work had no eligible repo-capable owner")
             )

      Cympho.AgentHeartbeat.stop_for_agent(new_id)
    end

    test "repo-delivery hires reject explicit text-only adapters", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      {:ok, _active} = saturate_agent(engineer)

      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Chat Engineer",
          "role" => "engineer",
          "adapter" => "openai_chat"
        }
      ]

      assert {:error, {:spawn_agent_repo_runtime_required, :engineer, "openai_chat"}} =
               AgentActions.execute(issue, ceo, actions)

      comments = Comments.list_comments(issue.id)
      assert Enum.any?(comments, &(&1.body =~ "must use a repo-capable runtime"))
      assert Enum.any?(comments, &(&1.body =~ "OpenAI Chat cannot edit files"))

      refute Enum.any?(
               Agents.list_agents_by_role(:engineer, ceo.company_id),
               &(&1.name == "Chat Engineer")
             )
    end

    test "CEO can hire a marketer for business-function work", %{ceo: ceo, issue: issue} do
      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Growth Marketer",
          "role" => "marketing"
        }
      ]

      assert {:ok, %{results: [%{type: "spawn_agent", agent_id: new_id, role: "marketer"}]}} =
               AgentActions.execute(issue, ceo, actions)

      {:ok, hired} = Agents.get_agent(new_id)
      assert hired.role == :marketer
      assert hired.title == "Marketer"
      assert hired.parent_id == ceo.id

      Cympho.AgentHeartbeat.stop_for_agent(new_id)
    end

    test "business-function hires can inherit a chat adapter from the parent", %{
      ceo: ceo,
      issue: issue
    } do
      {:ok, chat_ceo} = Agents.update_agent(ceo, %{adapter: :openai_chat})

      actions = [
        %{
          "type" => "spawn_agent",
          "name" => "Gateway Researcher",
          "role" => "researcher"
        }
      ]

      assert {:ok, %{results: [%{type: "spawn_agent", agent_id: new_id, role: "researcher"}]}} =
               AgentActions.execute(issue, chat_ceo, actions)

      {:ok, hired} = Agents.get_agent(new_id)
      assert hired.adapter == :openai_chat

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
          "reason" =>
            "Acceptance criteria: implement the scoped module change without expanding the parent issue. Evidence required: code diff or work product plus delivery note. Verification required: focused module test or named blocker. Definition of done: ready for CTO review with evidence and risk named."
        }
      ]

      assert {:ok, %{results: [%{type: "delegate", to_agent_id: target}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert target == engineer.id

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == engineer.id
      assert reloaded.assigned_role == "engineer"
      assert reloaded.status == :todo
      original_description = String.trim(issue.description || "")
      assert original_description != ""
      assert reloaded.description =~ original_description
      assert reloaded.description =~ "## Manager delegation brief"
      assert reloaded.description =~ "From: #{ceo.name} (ceo)"
      assert reloaded.description =~ "To: #{engineer.name} (engineer)"
      assert reloaded.description =~ "Directive:"
      assert reloaded.description =~ "Acceptance criteria: implement the scoped module change"

      [wake] = pending_wakes(engineer.id, "manager_directive")
      assert wake.metadata["reason"] =~ "Acceptance criteria"
      assert wake.metadata["from_agent_id"] == ceo.id
    end

    test "CEO cannot delegate a thin issue directly to an engineer", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      actions = [
        %{
          "type" => "delegate",
          "to_agent_id" => engineer.id,
          "reason" => "You know this part; please take it."
        }
      ]

      assert {:error,
              {:delegate_delivery_brief_too_thin, :engineer, next_prompt, missing, scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == ceo.id
      assert reloaded.assigned_role == "ceo"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "delegate rejected") and
                 String.contains?(comment.body, "directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(engineer.id, "manager_directive") == []
    end

    test "short target ids are rejected without crashing", %{
      ceo: ceo,
      engineer: engineer,
      issue: issue
    } do
      short_id = String.slice(engineer.id, 0, 8)

      actions = [
        %{
          "type" => "delegate",
          "to_agent_id" => short_id,
          "reason" =>
            "Acceptance criteria: implement the scoped module change without expanding the parent issue. Evidence required: code diff or work product plus delivery note. Verification required: focused module test or named blocker. Definition of done: ready for CTO review with evidence and risk named."
        }
      ]

      assert {:error, {:invalid_agent_target_id, "delegate", ^short_id}} =
               AgentActions.execute(issue, ceo, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == ceo.id
      assert reloaded.assigned_role == "ceo"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "delegate rejected") and
                 String.contains?(comment.body, "full agent UUID")
             end)

      assert pending_wakes(engineer.id, "manager_directive") == []
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
          "reason" => escalation_reason(),
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
      assert wake.metadata["reason"] =~ "Cause:"

      # CEO is unaffected.
      assert pending_wakes(ceo.id, "escalation_from_subordinate") == []
    end

    test "thin escalation is rejected before blocking the issue", %{
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      {:ok, engineer} = Agents.update_agent(engineer, %{parent_id: cto.id})

      {:ok, _} = Issues.force_release_issue(issue, :todo)
      {:ok, eng_issue} = Issues.checkout_issue(issue, engineer, :engineer)

      actions = [
        %{
          "type" => "escalate",
          "reason" => "Spec conflicts.",
          "to_role" => "cto"
        }
      ]

      assert {:error, {:escalation_reason_too_thin, missing, scaffold}} =
               AgentActions.execute(eng_issue, engineer, actions)

      assert "Needs" in missing
      assert "Current state" in missing
      assert "Next decision" in missing
      assert scaffold =~ "Current escalation: Spec conflicts."
      assert scaffold =~ "Restart packet:"

      reloaded = Issues.get_issue!(eng_issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == engineer.id
      assert reloaded.assigned_role == "engineer"

      comments = Comments.list_comments(eng_issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "escalate rejected") and
                 String.contains?(comment.body, "escalation reason is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(cto.id, "escalation_from_subordinate") == []
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

      actions = [%{"type" => "escalate", "reason" => escalation_reason()}]

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

  defp saturate_agent(agent) do
    Issues.create_issue(%{
      title: "Saturate #{agent.name}",
      description: "Consumes the existing agent slot for capacity-sensitive hire tests.",
      status: :in_progress,
      priority: :medium,
      company_id: agent.company_id,
      assignee_id: agent.id,
      assigned_role: to_string(agent.role)
    })
  end

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

  defp escalation_reason do
    """
    Cause: spec conflicts with itself and cannot be resolved at engineer authority.
    Attempted fix: reviewed the issue description and checked the implementation constraints.
    Needs: CTO chooses the correct interpretation or cuts scope.
    Current state: implementation is paused before code changes.
    Next decision: CTO decides which requirement wins.
    Restart packet: resume from the conflicting spec lines and either update scope or delegate a clarified implementation.
    """
    |> String.trim()
  end
end
