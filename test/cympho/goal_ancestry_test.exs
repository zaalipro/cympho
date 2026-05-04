defmodule Cympho.GoalAncestryTest do
  use Cympho.DataCase, async: true
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Issues

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{name: "Test Co", slug: "ga-#{System.unique_integer()}"})

    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>>

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "Test Project",
        prefix: prefix,
        company_id: company.id
      })

    {:ok, company: company, project: project}
  end

  describe "compute_goal_type/1" do
    test "root goal (no parent) is mission", %{project: project} do
      {:ok, goal} = Goals.create_goal(%{title: "Mission", project_id: project.id})
      assert Goals.compute_goal_type(goal) == :mission
    end

    test "child of root is initiative", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, child} =
        Goals.create_goal(%{title: "Initiative", project_id: project.id, parent_id: parent.id})

      assert Goals.compute_goal_type(child) == :initiative
    end

    test "grandchild is milestone", %{project: project} do
      {:ok, root} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, mid} =
        Goals.create_goal(%{title: "Initiative", project_id: project.id, parent_id: root.id})

      {:ok, leaf} =
        Goals.create_goal(%{title: "Milestone", project_id: project.id, parent_id: mid.id})

      assert Goals.compute_goal_type(leaf) == :milestone
    end
  end

  describe "list_missions/1" do
    test "returns only mission-type goals for company", %{company: company, project: project} do
      {:ok, mission} =
        Goals.create_goal(%{title: "Mission", project_id: project.id, company_id: company.id})

      {:ok, _initiative} =
        Goals.create_goal(%{
          title: "Initiative",
          project_id: project.id,
          company_id: company.id,
          parent_id: mission.id
        })

      missions = Goals.list_missions(company.id)
      assert length(missions) == 1
      assert hd(missions).id == mission.id
    end

    test "returns empty list for company with no missions" do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{name: "Other", slug: "oc-#{System.unique_integer()}"})

      assert Goals.list_missions(other_company.id) == []
    end
  end

  describe "compute_lineage/1" do
    test "returns nil for issue with no goal" do
      {:ok, issue} = Issues.create_issue(%{title: "No goal issue"})
      assert Goals.compute_lineage(issue) == nil
    end

    test "returns lineage for issue linked to a mission", %{project: project} do
      {:ok, mission} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "Issue", project_id: project.id, goal_id: mission.id})

      lineage = Goals.compute_lineage(issue)
      assert lineage != nil
      assert lineage.goal_id == mission.id
      assert lineage.project_id == project.id
      assert lineage.mission_id == mission.id
      assert lineage.initiative_id == nil
      assert lineage.milestone_id == nil
    end

    test "returns full lineage for issue linked to a milestone", %{project: project} do
      {:ok, mission} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, initiative} =
        Goals.create_goal(%{title: "Initiative", project_id: project.id, parent_id: mission.id})

      {:ok, milestone} =
        Goals.create_goal(%{title: "Milestone", project_id: project.id, parent_id: initiative.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "Deep Issue", project_id: project.id, goal_id: milestone.id})

      lineage = Goals.compute_lineage(issue)
      assert lineage.goal_id == milestone.id
      assert lineage.mission_id == mission.id
      assert lineage.initiative_id == initiative.id
      assert lineage.milestone_id == milestone.id
    end

    test "returns lineage for initiative-level issue", %{project: project} do
      {:ok, mission} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, initiative} =
        Goals.create_goal(%{title: "Initiative", project_id: project.id, parent_id: mission.id})

      {:ok, issue} =
        Issues.create_issue(%{
          title: "Init Issue",
          project_id: project.id,
          goal_id: initiative.id
        })

      lineage = Goals.compute_lineage(issue)
      assert lineage.goal_id == initiative.id
      assert lineage.mission_id == mission.id
      assert lineage.initiative_id == initiative.id
      assert lineage.milestone_id == nil
    end
  end

  describe "lineage on issue create/update" do
    test "issue creation with goal_id populates lineage", %{project: project} do
      {:ok, mission} = Goals.create_goal(%{title: "Mission", project_id: project.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "Created", project_id: project.id, goal_id: mission.id})

      assert issue.lineage != nil
      # Lineage uses atom keys in the returned struct (before DB reload)
      assert issue.lineage.goal_id == mission.id
      assert issue.lineage.mission_id == mission.id
    end

    test "updating goal_id recomputes lineage", %{project: project} do
      {:ok, mission1} = Goals.create_goal(%{title: "M1", project_id: project.id})
      {:ok, mission2} = Goals.create_goal(%{title: "M2", project_id: project.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "Issue", project_id: project.id, goal_id: mission1.id})

      assert issue.lineage.mission_id == mission1.id

      {:ok, updated} = Issues.update_issue(issue, %{goal_id: mission2.id})
      assert updated.lineage.mission_id == mission2.id
    end

    test "issue without goal has nil lineage", %{project: project} do
      {:ok, issue} = Issues.create_issue(%{title: "No goal", project_id: project.id})
      assert issue.lineage == nil
    end
  end
end
