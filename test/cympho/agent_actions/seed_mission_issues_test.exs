defmodule Cympho.AgentActions.SeedMissionIssuesTest do
  use Cympho.DataCase, async: false

  alias Cympho.AgentActions
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.BacklogPlanner
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  setup do
    {:ok,
     %{
       company: company,
       agents: [ceo, _cto, engineer | _],
       goal: mission_goal,
       seed_issues: _
     }} =
      Companies.create_autonomous_company(%{
        name: "Seed Co #{System.unique_integer([:positive])}",
        issue_prefix: "SED",
        engineer_count: 2
      })

    {:ok, planning_issue} = BacklogPlanner.ensure_planning_issue(company.id, ceo)

    %{
      company: company,
      ceo: ceo,
      engineer: engineer,
      mission_goal: mission_goal,
      planning_issue: planning_issue
    }
  end

  describe "seed_mission_issues" do
    test "CEO can seed initiatives under a mission goal",
         %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => goal.id,
          "initiatives" => [
            %{
              "title" => "Build onboarding flow",
              "description" => "Acceptance: new users hit aha moment.",
              "role" => "product_manager",
              "priority" => "high"
            },
            %{
              "title" => "Plan onboarding architecture",
              "description" => "Identify modules to change.",
              "role" => "cto",
              "priority" => "high"
            }
          ]
        }
      ]

      assert {:ok, %{results: [%{type: "seed_mission_issues"} = result]}} =
               AgentActions.execute(issue, ceo, actions)

      assert result.goal_id == goal.id
      assert length(result.created) == 2
      assert result.errors == []

      created =
        result.created
        |> Enum.map(& &1.issue_id)
        |> Enum.map(&Issues.get_issue!/1)

      assert Enum.all?(created, &(&1.goal_id == goal.id))
      assert Enum.all?(created, &is_nil(&1.parent_id))
      assert Enum.all?(created, &(&1.status == :todo))
      assert Enum.map(created, & &1.assigned_role) |> Enum.sort() == ["cto", "product_manager"]
    end

    test "rejects when emitter is not a CEO",
         %{engineer: engineer, mission_goal: goal, planning_issue: issue} do
      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => goal.id,
          "initiatives" => [
            %{"title" => "Sneaky", "role" => "engineer"}
          ]
        }
      ]

      # Engineer is the wrong role for this issue (planning is CEO-owned)
      # and also unauthorized for seed_mission_issues. The execute path
      # checks authorize_action before unresolved_current_issue?.
      assert {:error, _reason} = AgentActions.execute(issue, engineer, actions)

      # No initiative issues created.
      refute Repo.exists?(
               from i in Issue, where: i.goal_id == ^goal.id and i.title == "Sneaky"
             )
    end

    test "rejects when goal is not a mission",
         %{ceo: ceo, mission_goal: mission, planning_issue: issue} do
      {:ok, initiative} =
        Cympho.Goals.create_goal(%{
          title: "Not a mission",
          parent_id: mission.id,
          company_id: mission.company_id,
          project_id: mission.project_id,
          goal_type: :initiative
        })

      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => initiative.id,
          "initiatives" => [%{"title" => "X", "role" => "engineer"}]
        }
      ]

      assert {:error, {:goal_not_mission, :initiative}} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "rejects empty initiatives list", %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => goal.id,
          "initiatives" => []
        }
      ]

      assert {:error, :missing_initiatives} =
               AgentActions.execute(issue, ceo, actions)
    end

    test "rejects too many initiatives",
         %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      initiatives =
        for n <- 1..15 do
          %{"title" => "Initiative #{n}", "role" => "engineer"}
        end

      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => goal.id,
          "initiatives" => initiatives
        }
      ]

      assert {:error, {:too_many_initiatives, 8}} =
               AgentActions.execute(issue, ceo, actions)
    end
  end

  describe "Wakes.wake_for_mission_idle/3" do
    test "enqueues a mission_idle wake referencing the planning issue",
         %{ceo: ceo, planning_issue: issue, company: company} do
      assert {:ok, %AgentWake{} = wake} =
               Wakes.wake_for_mission_idle(ceo.id, issue.id, %{
                 "company_id" => company.id
               })

      assert wake.reason == "mission_idle"
      assert wake.agent_id == ceo.id
      assert wake.issue_id == issue.id
      assert wake.metadata["company_id"] == company.id
    end
  end
end
