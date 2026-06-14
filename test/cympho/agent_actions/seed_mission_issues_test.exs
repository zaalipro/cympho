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
              "description" =>
                "Context: activation drops before the aha moment.\nDefinition of done: onboarding path is ready for CTO spec review.\nEvidence to inspect: activation baseline, proposed funnel, and owner-facing success signal.",
              "role" => "product_manager",
              "priority" => "high"
            },
            %{
              "title" => "Plan onboarding architecture",
              "description" =>
                "Context: onboarding needs a technical plan before implementation.\nDefinition of done: modules, data model, and risk list are ready for review.\nEvidence to inspect: architecture brief and implementation split.",
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

      # CEO-seeded children land in :backlog assigned to CTO for spec review,
      # NOT directly into the proposed role pool. The proposed role survives
      # in monitor_state for the CTO to honor on approval.
      assert Enum.all?(created, &(&1.status == :backlog))
      assert Enum.all?(created, &(&1.assigned_role == "cto"))

      assert Enum.map(created, &get_in(&1.monitor_state, ["proposed_role"])) |> Enum.sort() ==
               ["cto", "product_manager"]

      assert Enum.all?(
               created,
               &(get_in(&1.monitor_state, ["spec_review_required"]) == true)
             )
    end

    test "CTO approving a spec-review child releases it into the proposed role pool",
         %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      # Pull the CTO out of the company's agent list.
      cto = Cympho.Agents.list_agents_by_role(:cto) |> List.first()
      assert cto != nil

      {:ok, %{results: [%{created: [%{issue_id: child_id} | _]} | _]}} =
        AgentActions.execute(issue, ceo, [
          %{
            "type" => "seed_mission_issues",
            "goal_id" => goal.id,
            "initiatives" => [
              %{
                "title" => "Build onboarding flow",
                "description" =>
                  "Context: onboarding needs implementation after CEO prioritization.\nDefinition of done: engineering scope is ready for release into the pool.\nEvidence to inspect: spec-ready brief, acceptance criteria, and risks.",
                "role" => "engineer",
                "priority" => "high"
              }
            ]
          }
        ])

      child = Issues.get_issue!(child_id)
      assert child.status == :backlog
      assert child.assigned_role == "cto"

      # CTO approves the spec.
      assert {:ok, %{results: [%{type: "approve_issue", subtype: "spec_approval"}]}} =
               AgentActions.execute(child, cto, [
                 %{
                   "type" => "approve_issue",
                   "notes" =>
                     "Acceptance criteria: onboarding flow implementation scope is clear. Evidence required: code change or work product plus delivery note. Verification required: focused onboarding smoke check. Definition of done: ready for CTO review with evidence and risk named."
                 }
               ])

      reloaded = Issues.get_issue!(child_id)

      assert reloaded.status == :todo
      assert reloaded.assigned_role == "engineer"
      refute reloaded.status == :done

      assert get_in(reloaded.monitor_state, ["spec_review_required"]) == nil
      assert get_in(reloaded.monitor_state, ["proposed_role"]) == nil
      assert get_in(reloaded.monitor_state, ["spec_approved_role_release"]) == "engineer"
      assert reloaded.description =~ "## CTO spec approval"

      assert reloaded.description =~
               "Acceptance criteria: onboarding flow implementation scope is clear."

      comments = Cympho.Comments.list_comments(child_id)

      assert Enum.any?(comments, fn c ->
               c.author_type == "agent" and
                 String.starts_with?(c.body, "[spec-approved]")
             end)
    end

    test "CTO cannot release repo-bound spec review with a thin delivery brief",
         %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      cto = Cympho.Agents.list_agents_by_role(:cto) |> List.first()
      assert cto != nil

      {:ok, %{results: [%{created: [%{issue_id: child_id} | _]} | _]}} =
        AgentActions.execute(issue, ceo, [
          %{
            "type" => "seed_mission_issues",
            "goal_id" => goal.id,
            "initiatives" => [
              %{
                "title" => "Build checkout telemetry",
                "description" =>
                  "Context: checkout telemetry is needed for owner reporting.\nDefinition of done: telemetry scope is ready for CTO spec review.\nEvidence to inspect: metric list and business risk.",
                "role" => "engineer",
                "priority" => "high"
              }
            ]
          }
        ])

      child = Issues.get_issue!(child_id)

      assert {:error,
              {:spec_review_delivery_brief_too_thin, :engineer, next_prompt, missing, scaffold}} =
               AgentActions.execute(child, cto, [
                 %{
                   "type" => "approve_issue",
                   "notes" => "Spec is clear; releasing to engineering."
                 }
               ])

      assert next_prompt =~ "Acceptance criteria"
      assert "Acceptance criteria" in missing
      assert scaffold =~ "Delivery goal: Build checkout telemetry"

      reloaded = Issues.get_issue!(child_id)
      assert reloaded.status == :backlog
      assert reloaded.assigned_role == "cto"
      assert get_in(reloaded.monitor_state, ["spec_review_required"]) == true

      comments = Cympho.Comments.list_comments(child_id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "approve_issue rejected") and
                 String.contains?(comment.body, "release brief is too thin") and
                 String.contains?(comment.body, "Repair scaffold")
             end)
    end

    test "rejects thin initiative briefs before seeding mission backlog",
         %{ceo: ceo, mission_goal: goal, planning_issue: issue} do
      actions = [
        %{
          "type" => "seed_mission_issues",
          "goal_id" => goal.id,
          "initiatives" => [
            %{
              "title" => "Build something valuable",
              "role" => "engineer",
              "priority" => "high"
            }
          ]
        }
      ]

      assert {:error,
              {:mission_initiative_too_thin, "Build something valuable", next_prompt, missing,
               scaffold}} = AgentActions.execute(issue, ceo, actions)

      assert next_prompt =~ "Context"
      assert "Context" in missing
      assert scaffold =~ "Goal: Build something valuable"
      assert scaffold =~ "Definition of done:"

      comments = Cympho.Comments.list_comments(issue.id)

      assert Enum.any?(comments, fn comment ->
               comment.author_type == "system" and
                 String.contains?(comment.body, "seed_mission_issues rejected") and
                 String.contains?(comment.body, "Build something valuable") and
                 String.contains?(comment.body, "Repair scaffold")
             end)

      refute Repo.exists?(
               from i in Issue,
                 where: i.goal_id == ^goal.id and i.title == "Build something valuable"
             )
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
      refute Repo.exists?(from i in Issue, where: i.goal_id == ^goal.id and i.title == "Sneaky")
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
