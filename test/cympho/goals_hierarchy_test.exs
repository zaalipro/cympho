defmodule Cympho.GoalsHierarchyTest do
  use Cympho.DataCase, async: true
  alias Cympho.Goals
  alias Cympho.Goals.Goal

  setup do
    company = insert(:company)
    project = insert(:project, company_id: company.id)
    {:ok, company: company, project: project}
  end

  describe "goal hierarchy" do
    test "create a goal with parent", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent Goal", project_id: project.id})
      {:ok, child} = Goals.create_goal(%{title: "Child Goal", project_id: project.id, parent_id: parent.id})

      assert child.parent_id == parent.id
    end

    test "get_goal_with_tree! loads nested children", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent", project_id: project.id})
      {:ok, _child1} = Goals.create_goal(%{title: "Child 1", project_id: project.id, parent_id: parent.id})
      {:ok, _child2} = Goals.create_goal(%{title: "Child 2", project_id: project.id, parent_id: parent.id})

      tree = Goals.get_goal_with_tree!(parent.id)
      assert length(tree.children) == 2
    end

    test "cycle detection prevents circular references", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent", project_id: project.id})
      {:ok, child} = Goals.create_goal(%{title: "Child", project_id: project.id, parent_id: parent.id})

      assert Goals.would_create_cycle?(parent.id, child.id)
    end

    test "self-reference is detected as cycle", %{project: project} do
      {:ok, goal} = Goals.create_goal(%{title: "Goal", project_id: project.id})
      assert Goals.would_create_cycle?(goal.id, goal.id)
    end

    test "unrelated goals are not a cycle", %{project: project} do
      {:ok, g1} = Goals.create_goal(%{title: "Goal 1", project_id: project.id})
      {:ok, g2} = Goals.create_goal(%{title: "Goal 2", project_id: project.id})
      refute Goals.would_create_cycle?(g1.id, g2.id)
    end
  end

  describe "goal progress" do
    test "calculates progress from linked issues", %{project: project} do
      {:ok, goal} = Goals.create_goal(%{title: "Goal", project_id: project.id})

      insert(:issue, project_id: project.id, goal_id: goal.id, status: :done)
      insert(:issue, project_id: project.id, goal_id: goal.id, status: :done)
      insert(:issue, project_id: project.id, goal_id: goal.id, status: :in_progress)

      progress = Goals.goal_progress(goal.id)
      assert progress.total == 3
      assert progress.done == 2
      assert progress.percent == 67
    end

    test "zero issues returns 0 percent", %{project: project} do
      {:ok, goal} = Goals.create_goal(%{title: "Empty Goal", project_id: project.id})
      progress = Goals.goal_progress(goal.id)
      assert progress.total == 0
      assert progress.percent == 0
    end
  end

  describe "list_root_goals_by_project" do
    test "returns only top-level goals", %{project: project} do
      {:ok, root1} = Goals.create_goal(%{title: "Root 1", project_id: project.id})
      {:ok, _child} = Goals.create_goal(%{title: "Child", project_id: project.id, parent_id: root1.id})
      {:ok, _root2} = Goals.create_goal(%{title: "Root 2", project_id: project.id})

      roots = Goals.list_root_goals_by_project(project.id)
      assert length(roots) == 2
    end
  end
end
