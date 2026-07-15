defmodule Cympho.GoalsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Goals.Goal
  alias Cympho.Issues
  alias Cympho.Projects

  describe "list_goals/0" do
    test "returns all goals" do
      {:ok, goal} = Goals.create_goal(%{title: "Test Goal"})
      goals = Goals.list_goals()
      assert length(goals) >= 1
      assert Enum.any?(goals, fn g -> g.id == goal.id end)
    end

    test "returns empty list when no goals exist" do
      goals = Goals.list_goals()
      assert goals == []
    end
  end

  describe "list_goals_by_project/1" do
    test "returns goals for a given project" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Goals Co",
          slug: "goals-co-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ", company_id: company.id})

      {:ok, goal} = Goals.create_goal(%{title: "Project Goal", project_id: project.id})
      {:ok, _other} = Goals.create_goal(%{title: "Other Goal"})

      goals = Goals.list_goals_by_project(project.id)
      assert length(goals) == 1
      assert hd(goals).id == goal.id
    end

    test "returns empty list for project with no goals" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Empty Goals Co",
          slug: "empty-goals-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Empty", prefix: "EMP", company_id: company.id})

      assert [] = Goals.list_goals_by_project(project.id)
    end
  end

  describe "get_goal!/1" do
    test "returns the goal with given id" do
      {:ok, goal} = Goals.create_goal(%{title: "Test Goal"})
      found = Goals.get_goal!(goal.id)
      assert found.id == goal.id
      assert found.title == goal.title
    end

    test "raises Ecto.NoResultsError for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Goals.get_goal!("00000000-0000-0000-0000-000000000000")
      end
    end
  end

  describe "get_goal/1" do
    test "returns {:ok, goal} for valid id" do
      {:ok, goal} = Goals.create_goal(%{title: "Test Goal"})
      assert {:ok, found} = Goals.get_goal(goal.id)
      assert found.id == goal.id
    end

    test "returns {:error, :not_found} for non-existent id" do
      assert {:error, :not_found} = Goals.get_goal("00000000-0000-0000-0000-000000000000")
    end
  end

  describe "create_goal/1" do
    test "creates goal with valid data" do
      attrs = %{title: "New Goal", description: "A goal description"}
      assert {:ok, %Goal{} = goal} = Goals.create_goal(attrs)
      assert goal.title == "New Goal"
      assert goal.description == "A goal description"
      assert goal.status == "active"
      assert goal.priority == "medium"
    end

    test "creates goal with all fields" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Full Goals Co",
          slug: "full-goals-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ", company_id: company.id})

      attrs = %{
        title: "Full Goal",
        description: "Desc",
        status: "completed",
        priority: "high",
        project_id: project.id
      }

      assert {:ok, %Goal{} = goal} = Goals.create_goal(attrs)
      assert goal.title == "Full Goal"
      assert goal.status == "completed"
      assert goal.priority == "high"
      assert goal.project_id == project.id
    end

    test "returns error changeset for missing title" do
      attrs = %{description: "No title"}
      assert {:error, %Ecto.Changeset{}} = Goals.create_goal(attrs)
    end

    test "returns error changeset for empty title" do
      attrs = %{title: ""}
      assert {:error, %Ecto.Changeset{}} = Goals.create_goal(attrs)
    end

    test "returns error changeset for invalid status" do
      attrs = %{title: "Test", status: "invalid"}
      assert {:error, %Ecto.Changeset{}} = Goals.create_goal(attrs)
    end

    test "returns error changeset for invalid priority" do
      attrs = %{title: "Test", priority: "urgent"}
      assert {:error, %Ecto.Changeset{}} = Goals.create_goal(attrs)
    end

    test "returns error changeset for non-existent project_id" do
      attrs = %{title: "Test", project_id: "00000000-0000-0000-0000-000000000000"}
      assert {:error, %Ecto.Changeset{}} = Goals.create_goal(attrs)
    end
  end

  describe "update_goal/2" do
    test "updates goal with valid data" do
      {:ok, goal} = Goals.create_goal(%{title: "Original"})
      attrs = %{title: "Updated", status: "completed"}
      assert {:ok, updated} = Goals.update_goal(goal, attrs)
      assert updated.title == "Updated"
      assert updated.status == "completed"
    end

    test "updates goal priority" do
      {:ok, goal} = Goals.create_goal(%{title: "Test"})
      attrs = %{priority: "critical"}
      assert {:ok, updated} = Goals.update_goal(goal, attrs)
      assert updated.priority == "critical"
    end

    test "returns error changeset for invalid data" do
      {:ok, goal} = Goals.create_goal(%{title: "Test"})
      attrs = %{title: ""}
      assert {:error, %Ecto.Changeset{}} = Goals.update_goal(goal, attrs)
    end
  end

  describe "delete_goal/1" do
    test "deletes the goal" do
      {:ok, goal} = Goals.create_goal(%{title: "To Delete"})
      assert {:ok, _} = Goals.delete_goal(goal)

      assert_raise Ecto.NoResultsError, fn ->
        Goals.get_goal!(goal.id)
      end
    end
  end

  describe "change_goal/2" do
    test "returns a changeset" do
      {:ok, goal} = Goals.create_goal(%{title: "Test"})
      changeset = Goals.change_goal(goal, %{title: "New Title"})
      assert changeset.changes[:title] == "New Title"
    end

    test "returns empty changeset with no attrs" do
      {:ok, goal} = Goals.create_goal(%{title: "Test"})
      changeset = Goals.change_goal(goal)
      assert changeset.changes == %{}
    end
  end

  describe "alignment_summary/2" do
    test "summarizes open work linked to goals, project-only work, and floating work" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Alignment Corp",
          slug: "alignment-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Aligned Project",
          prefix: "ALN",
          company_id: company.id
        })

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Win the market",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, idle_goal} =
        Goals.create_goal(%{
          title: "Prepare next bet",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _aligned} =
        Issues.create_issue(%{
          title: "Goal-linked work",
          company_id: company.id,
          project_id: project.id,
          goal_id: mission.id,
          status: :todo,
          priority: :high
        })

      {:ok, _project_only} =
        Issues.create_issue(%{
          title: "Project-only work",
          company_id: company.id,
          project_id: project.id,
          status: :in_progress,
          priority: :medium
        })

      {:ok, _floating} =
        Issues.create_issue(%{
          title: "Floating critical work",
          company_id: company.id,
          status: :blocked,
          priority: :critical
        })

      {:ok, _done} =
        Issues.create_issue(%{
          title: "Completed old work",
          company_id: company.id,
          goal_id: idle_goal.id,
          status: :done
        })

      summary = Goals.alignment_summary(company.id)

      assert summary.total_open == 3
      assert summary.mission_aligned == 1
      assert summary.project_only == 1
      assert summary.floating == 1
      assert summary.active_goals == 2
      assert summary.active_missions == 2
      assert summary.goals_with_work == 1
      assert summary.goals_without_work == 1
      assert summary.aligned_percent == 33
      assert summary.linked_percent == 67
      assert summary.status == :floating_work
      assert [%{title: "Floating critical work"} | _] = summary.risk_issues
    end
  end

  describe "goal_work_health/1" do
    test "rolls issue status health up by company goal" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Goal Health Corp",
          slug: "goal-health-#{System.unique_integer([:positive])}"
        })

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Goal Health Corp",
          slug: "other-goal-health-#{System.unique_integer([:positive])}"
        })

      {:ok, project} =
        Projects.create_project(%{
          name: "Goal Health Project",
          prefix: "GHP",
          company_id: company.id
        })

      {:ok, mission} =
        Goals.create_goal(%{
          title: "Improve goal health",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _other_mission} =
        Goals.create_goal(%{
          title: "Other company goal",
          company_id: other_company.id,
          goal_type: :mission
        })

      for status <- [:backlog, :todo, :in_progress, :in_review, :blocked, :done, :cancelled] do
        {:ok, _issue} =
          Issues.create_issue(%{
            title: "Goal health #{status}",
            company_id: company.id,
            project_id: project.id,
            goal_id: mission.id,
            status: status
          })
      end

      {:ok, _unlinked} =
        Issues.create_issue(%{
          title: "Unlinked work",
          company_id: company.id,
          status: :todo
        })

      {:ok, _foreign} =
        Issues.create_issue(%{
          title: "Foreign goal work",
          company_id: other_company.id,
          status: :todo
        })

      health = Goals.goal_work_health(company.id)[mission.id]

      assert health.total == 7
      assert health.ready == 2
      assert health.in_progress == 1
      assert health.in_review == 1
      assert health.blocked == 1
      assert health.open == 5
      assert health.done == 1
      assert health.cancelled == 1
      assert health.progress_percent == 14
      assert %DateTime{} = health.last_activity_at
      assert map_size(Goals.goal_work_health(company.id)) == 1
    end
  end
end
