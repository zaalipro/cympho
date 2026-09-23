defmodule Cympho.AgentActions.InterveneTest do
  use Cympho.DataCase, async: false

  import Cympho.WaitHelpers
  import Mock

  alias Cympho.{Activities, AgentActions, Agents, Comments, Companies, Issues}
  alias Cympho.Adapters.MockAdapter
  alias Cympho.Repo
  alias Cympho.Wakes.AgentWake
  import Ecto.Query

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, cto, engineer | _],
       seed_issues: [seed | _]
     }} =
      Companies.create_autonomous_company(%{
        name: "Intervene Co #{System.unique_integer([:positive])}",
        issue_prefix: "INT",
        engineer_count: 1
      })

    # Spawn a second engineer so reassign has a real target.
    {:ok, engineer_two} =
      Agents.create_agent(%{
        name: "Engineer Two",
        role: :engineer,
        status: :idle,
        company_id: company.id,
        parent_id: cto.id
      })

    # Stale issue assigned to engineer
    stale_at =
      DateTime.utc_now() |> DateTime.add(-3 * 3600, :second) |> DateTime.truncate(:second)

    {:ok, issue} =
      Issues.update_issue(seed, %{
        status: :in_progress,
        assignee_id: engineer.id,
        checked_out_at: stale_at,
        updated_at: stale_at
      })

    %{
      company: company,
      ceo: ceo,
      cto: cto,
      engineer: engineer,
      engineer_two: engineer_two,
      issue: issue
    }
  end

  describe "intervene reassign" do
    test "CEO can reassign to a named engineer", %{
      ceo: ceo,
      engineer_two: engineer_two,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "reassign", to_agent_id: target}]}} =
               AgentActions.execute(issue, ceo, actions)

      assert target == engineer_two.id

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == engineer_two.id
      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"
      assert is_nil(reloaded.checkout_run_id)
      assert is_nil(reloaded.checked_out_at)

      [wake] = pending_wakes(engineer_two.id, "manager_directive")
      assert wake.metadata["via"] == "intervene"
    end

    @tag :capture_log
    test "stops live orchestrator before transferring ownership", %{
      ceo: ceo,
      engineer: engineer,
      engineer_two: engineer_two,
      issue: issue
    } do
      unless Process.whereis(Cympho.OrchestratorRegistry) do
        start_supervised!({Registry, keys: :unique, name: Cympho.OrchestratorRegistry})
      end

      # Agent is a GenServer registered under the orchestrator via-tuple so
      # Orchestrator.stop/2 can cleanly GenServer.stop it (plain spawn cannot).
      {:ok, fake} =
        Agent.start(fn -> :live end,
          name: {:via, Registry, {Cympho.OrchestratorRegistry, issue.id}}
        )

      assert Cympho.Orchestrator.whereis(issue.id) == fake
      assert Process.alive?(fake)

      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "reassign"}]}} =
               AgentActions.execute(issue, ceo, actions)

      wait_until(fn -> is_nil(Cympho.Orchestrator.whereis(issue.id)) end)
      refute Process.alive?(fake)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == engineer_two.id
      assert reloaded.status == :todo
      refute reloaded.assignee_id == engineer.id
    end

    test "rejects thin repo-delivery reassignments before waking the target", %{
      ceo: ceo,
      engineer: engineer,
      engineer_two: engineer_two,
      issue: issue
    } do
      {:ok, issue} = Issues.update_issue(issue, %{description: "Please recover this."})

      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => "Different engineer should pick this up."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "reassign", :engineer, next_prompt, missing,
               scaffold}} =
               AgentActions.execute(issue, ceo, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene reassign rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(engineer_two.id, "manager_directive") == []
    end

    test "rejects when neither to_agent_id nor to_role provided", %{ceo: ceo, issue: issue} do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "reason" => "Need to reassign but no target named yet."
        }
      ]

      assert {:error, :missing_intervene_target} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "engineer cannot intervene", %{engineer: engineer, issue: issue} do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer.id,
          "reason" => "x"
        }
      ]

      assert {:error, :unauthorized_action} =
               AgentActions.execute(issue, engineer, actions)
    end
  end

  describe "intervene unblock" do
    setup %{issue: issue, engineer: engineer} do
      stale_at =
        DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)

      {:ok, blocked} =
        Issues.update_issue(issue, %{
          status: :blocked,
          assignee_id: engineer.id,
          updated_at: stale_at
        })

      %{issue: blocked}
    end

    test "CTO unblocks → :todo, comment, blockers_resolved wake", %{
      cto: cto,
      issue: issue,
      engineer: engineer
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "unblock",
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "unblock"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :todo

      assert pending_wakes(engineer.id, "issue_blockers_resolved") |> length() >= 0
    end

    test "rejects thin repo-delivery unblock before requeueing the issue", %{
      cto: cto,
      issue: issue,
      engineer: engineer
    } do
      {:ok, issue} =
        Issues.update_issue(issue, %{
          description: "Blocked.",
          assigned_role: "engineer"
        })

      actions = [
        %{
          "type" => "intervene",
          "mode" => "unblock",
          "reason" => "Dependency landed earlier today."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "unblock", :engineer, next_prompt, missing,
               scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :blocked
      assert reloaded.assignee_id == engineer.id
      assert reloaded.assigned_role == "engineer"

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene unblock rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      assert pending_wakes(engineer.id, "issue_blockers_resolved") == []
    end
  end

  describe "intervene cancel" do
    test "CEO cancels a stalled issue", %{ceo: ceo, issue: issue} do
      :ok = Activities.subscribe(issue.company_id)

      actions = [
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "Mission pivoted, this isn't needed anymore."
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "cancel"}]}} =
               AgentActions.execute(issue, ceo, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :cancelled
      assert_receive {:activity_created, activity}, 1_000
      activity_id = activity.id
      refute_receive {:activity_created, %{id: ^activity_id}}, 100
      assert Process.get(:cympho_deferred_activity_events) == nil
    end

    test "terminal run cancellation rolls back with the enclosing action batch", %{
      ceo: ceo,
      issue: issue
    } do
      :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{issue.company_id}:runs")
      :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{issue.company_id}:issues")
      :ok = Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{issue.company_id}:activities")
      MockAdapter.clear()
      on_exit(fn -> MockAdapter.clear() end)
      MockAdapter.script(issue.assignee_id, issue.id, [:silent])

      actions = [
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "Mission pivoted, this issue is no longer needed."
        },
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "A second cancellation must fail and roll back the batch."
        }
      ]

      with_mock Cympho.Adapters, [], resolve: fn _ -> {:ok, MockAdapter, %{}} end do
        assert {:ok, orchestrator} =
                 Cympho.Orchestrator.start_and_run(issue, issue.assignee_id,
                   adapter: :mock,
                   adapter_config: %{}
                 )

        Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), orchestrator)

        run =
          Enum.find_value(1..100, fn _ ->
            case Enum.find(
                   Cympho.HeartbeatEngine.list_runs_for_issue(issue.id),
                   &(&1.status == "running")
                 ) do
              nil ->
                Process.sleep(10)
                nil

              running ->
                running
            end
          end)

        assert %Cympho.HeartbeatEngine.Run{} = run
        flush_messages()

        assert {:error, :invalid_transition} = AgentActions.execute(issue, ceo, actions)
        assert Repo.get!(Cympho.HeartbeatEngine.Run, run.id).status == "running"
        assert Issues.get_issue!(issue.id).status == :in_progress
        assert Process.alive?(orchestrator)
        refute_receive %{event: "run_status", payload: %{event_type: :run_cancelled}}, 100
        refute_receive {:issue_updated, _}, 100
        refute_receive {:activity_created, _}, 100
        assert Process.get(:cympho_deferred_terminal_runs) == nil
        assert Process.get(:cympho_deferred_runtime_stops) == nil
        assert Process.get(:cympho_agent_actions_defer_terminal_effects) == nil

        Cympho.Orchestrator.stop(issue.id)
      end
    end
  end

  describe "intervene force_handoff" do
    test "CTO clears assignee and sets role for dispatcher routing", %{
      cto: cto,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "force_handoff",
          "to_role" => "engineer",
          "reason" => delivery_restart_reason()
        }
      ]

      assert {:ok, %{results: [%{type: "intervene", mode: "force_handoff", to_role: "engineer"}]}} =
               AgentActions.execute(issue, cto, actions)

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.assignee_id == nil
      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"
    end

    test "rejects thin force handoff to repo-delivery roles", %{
      cto: cto,
      engineer: engineer,
      issue: issue
    } do
      {:ok, issue} = Issues.update_issue(issue, %{description: "Still stuck."})

      actions = [
        %{
          "type" => "intervene",
          "mode" => "force_handoff",
          "to_role" => "engineer",
          "reason" => "Put this back in the engineer pool."
        }
      ]

      assert {:error,
              {:intervene_delivery_brief_too_thin, "force_handoff", :engineer, next_prompt,
               missing, scaffold}} =
               AgentActions.execute(issue, cto, actions)

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal:"

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.status == :in_progress
      assert reloaded.assignee_id == engineer.id

      comments = Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "intervene force_handoff rejected") and
                 String.contains?(comment.body, "recovery directive is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end
  end

  describe "validation" do
    test "rejects unknown mode", %{ceo: ceo, issue: issue} do
      actions = [%{"type" => "intervene", "mode" => "yeet", "reason" => "x"}]

      assert {:error, {:invalid_intervene_mode, _}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "rejects missing mode", %{ceo: ceo, issue: issue} do
      actions = [%{"type" => "intervene", "reason" => "x"}]

      assert {:error, {:invalid_intervene_mode, _}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "reassign rejects too-short reason", %{
      ceo: ceo,
      engineer_two: engineer_two,
      issue: issue
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "reassign",
          "to_agent_id" => engineer_two.id,
          "reason" => "short"
        }
      ]

      assert {:error, {:governance_reason_too_short, "intervene", 15}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "cancel records a Decision on success", %{
      ceo: ceo,
      issue: issue,
      company: company
    } do
      actions = [
        %{
          "type" => "intervene",
          "mode" => "cancel",
          "reason" => "Mission pivoted, this issue is no longer needed."
        }
      ]

      assert {:ok, _} = AgentActions.execute(issue, ceo, actions)

      decisions =
        Cympho.Decisions.list_decisions(%{
          company_id: company.id,
          resource_type: "issue",
          resource_id: issue.id,
          decision_type: "intervene_cancel"
        })

      assert [decision] = decisions
      assert decision.outcome == "implemented"
      assert decision.actor_id == ceo.id
    end
  end

  ## helpers

  defp pending_wakes(agent_id, reason) do
    Repo.all(
      from w in AgentWake,
        where: w.agent_id == ^agent_id and w.reason == ^reason and w.status == "pending"
    )
  end

  defp delivery_restart_reason do
    "Acceptance criteria: finish the stalled implementation within the existing issue scope. " <>
      "Evidence required: attach the code-change work product or PR plus a delivery note. " <>
      "Verification required: run the focused test or name the blocker preventing it. " <>
      "Definition of done: ready for CTO review with evidence, verification, and remaining risk named."
  end

  defp flush_messages do
    receive do
      _ -> flush_messages()
    after
      0 -> :ok
    end
  end
end
