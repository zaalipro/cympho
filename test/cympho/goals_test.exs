defmodule Cympho.GoalsTest do
  use Cympho.DataCase, async: true

  alias Cympho.Goals
  alias Cympho.Goals.Goal

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
      {:ok, project} = Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ"})
      {:ok, goal} = Goals.create_goal(%{title: "Project Goal", project_id: project.id})
      {:ok, _other} = Goals.create_goal(%{title: "Other Goal"})

      goals = Goals.list_goals_by_project(project.id)
      assert length(goals) == 1
      assert hd(goals).id == goal.id
    end

    test "returns empty list for project with no goals" do
      {:ok, project} = Cympho.Projects.create_project(%{name: "Empty", prefix: "EMP"})
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
      {:ok, project} = Cympho.Projects.create_project(%{name: "Proj", prefix: "PRJ"})
      attrs = %{title: "Full Goal", description: "Desc", status: "completed", priority: "high", project_id: project.id}
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
end
