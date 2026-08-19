defmodule Cympho.GoalsHierarchyTest do
  use Cympho.DataCase, async: true
  alias Cympho.Goals

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{name: "Test Co", slug: "gh-#{System.unique_integer()}"})

    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>>

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "Test Project",
        prefix: prefix,
        company_id: company.id
      })

    {:ok, company: company, project: project}
  end

  describe "goal hierarchy" do
    test "create a goal with parent", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent Goal", project_id: project.id})

      {:ok, child} =
        Goals.create_goal(%{title: "Child Goal", project_id: project.id, parent_id: parent.id})

      assert child.parent_id == parent.id
      assert child.company_id == project.company_id
    end

    test "get_goal_with_tree! loads nested children", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent", project_id: project.id})

      {:ok, _child1} =
        Goals.create_goal(%{title: "Child 1", project_id: project.id, parent_id: parent.id})

      {:ok, _child2} =
        Goals.create_goal(%{title: "Child 2", project_id: project.id, parent_id: parent.id})

      tree = Goals.get_goal_with_tree!(parent.id)
      assert length(tree.children) == 2
    end

    test "cycle detection prevents circular references", %{project: project} do
      {:ok, parent} = Goals.create_goal(%{title: "Parent", project_id: project.id})

      {:ok, child} =
        Goals.create_goal(%{title: "Child", project_id: project.id, parent_id: parent.id})

      assert Goals.would_create_cycle?(parent.id, child.id)

      assert {:error, changeset} = Goals.update_goal(parent, %{parent_id: child.id})
      assert %{parent_id: ["would create a cycle"]} = errors_on(changeset)
      assert Goals.get_goal!(parent.id).parent_id == nil
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

    test "create and update reject cross-company projects and parents", %{
      company: company,
      project: project
    } do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Goal Co",
          slug: "other-goal-#{System.unique_integer([:positive])}"
        })

      {:ok, other_project} =
        Cympho.Projects.create_project(%{
          name: "Other Goal Project",
          prefix: "OTH",
          company_id: other_company.id
        })

      {:ok, other_parent} =
        Goals.create_goal(%{
          title: "Other Parent",
          company_id: other_company.id,
          project_id: other_project.id
        })

      assert {:error, create_changeset} =
               Goals.create_goal(%{
                 title: "Forged child",
                 company_id: company.id,
                 project_id: other_project.id,
                 parent_id: other_parent.id
               })

      assert %{
               project_id: ["must belong to the same company"],
               parent_id: ["must belong to the same company"]
             } = errors_on(create_changeset)

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Our Goal",
          company_id: company.id,
          project_id: project.id
        })

      assert {:error, update_changeset} =
               Goals.update_goal(goal, %{
                 project_id: other_project.id,
                 parent_id: other_parent.id
               })

      assert %{
               project_id: ["must belong to the same company"],
               parent_id: ["must belong to the same company"]
             } = errors_on(update_changeset)

      unchanged = Goals.get_goal!(goal.id)
      assert unchanged.project_id == project.id
      assert unchanged.parent_id == nil
    end

    test "update ignores a forged company_id", %{company: company, project: project} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Forged Tenant",
          slug: "forged-tenant-#{System.unique_integer([:positive])}"
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "Tenant-bound goal",
          company_id: company.id,
          project_id: project.id
        })

      assert {:ok, updated} =
               Goals.update_goal(goal, %{title: "Still ours", company_id: other_company.id})

      assert updated.title == "Still ours"
      assert updated.company_id == company.id
    end

    test "legacy cycles do not recurse forever and cannot gain new children", %{
      company: company,
      project: project
    } do
      {:ok, a} =
        Goals.create_goal(%{
          title: "Legacy A",
          company_id: company.id,
          project_id: project.id
        })

      {:ok, b} =
        Goals.create_goal(%{
          title: "Legacy B",
          company_id: company.id,
          project_id: project.id,
          parent_id: a.id
        })

      {1, nil} =
        Repo.update_all(from(g in Cympho.Goals.Goal, where: g.id == ^a.id),
          set: [parent_id: b.id]
        )

      assert Enum.map(Goals.get_ancestors(a.id), & &1.id) == [b.id]
      assert Enum.map(Goals.get_descendants(a.id), & &1.id) == [b.id]

      tree = Goals.get_goal_with_tree!(a.id)
      assert [%{id: b_id, children: []}] = tree.children
      assert b_id == b.id

      assert {:error, changeset} =
               Goals.create_goal(%{
                 title: "Must not attach",
                 company_id: company.id,
                 parent_id: a.id
               })

      assert %{parent_id: ["would create a cycle"]} = errors_on(changeset)
    end
  end

  describe "goal progress" do
    test "calculates progress from linked issues", %{project: project} do
      {:ok, goal} = Goals.create_goal(%{title: "Goal", project_id: project.id})

      {:ok, _} =
        Cympho.Issues.create_issue(%{
          title: "I1",
          project_id: project.id,
          goal_id: goal.id,
          status: :done
        })

      {:ok, _} =
        Cympho.Issues.create_issue(%{
          title: "I2",
          project_id: project.id,
          goal_id: goal.id,
          status: :done
        })

      {:ok, _} =
        Cympho.Issues.create_issue(%{
          title: "I3",
          project_id: project.id,
          goal_id: goal.id,
          status: :in_progress
        })

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

      {:ok, _child} =
        Goals.create_goal(%{title: "Child", project_id: project.id, parent_id: root1.id})

      {:ok, _root2} = Goals.create_goal(%{title: "Root 2", project_id: project.id})

      roots = Goals.list_root_goals_by_project(project.id)
      assert length(roots) == 2
    end
  end

  describe "get_ancestors/1" do
    test "returns empty list for root goal", %{project: project} do
      {:ok, root} = Goals.create_goal(%{title: "Root", project_id: project.id})
      assert Goals.get_ancestors(root.id) == []
    end

    test "returns parent chain for nested goals", %{project: project} do
      {:ok, grandparent} = Goals.create_goal(%{title: "GP", project_id: project.id})

      {:ok, parent} =
        Goals.create_goal(%{title: "P", project_id: project.id, parent_id: grandparent.id})

      {:ok, child} =
        Goals.create_goal(%{title: "C", project_id: project.id, parent_id: parent.id})

      ancestors = Goals.get_ancestors(child.id)
      assert length(ancestors) == 2
      assert Enum.at(ancestors, 0).id == grandparent.id
      assert Enum.at(ancestors, 1).id == parent.id
    end
  end

  describe "get_descendants/1" do
    test "returns empty list for leaf goal", %{project: project} do
      {:ok, leaf} = Goals.create_goal(%{title: "Leaf", project_id: project.id})
      assert Goals.get_descendants(leaf.id) == []
    end

    test "returns all nested children recursively", %{project: project} do
      {:ok, root} = Goals.create_goal(%{title: "Root", project_id: project.id})

      {:ok, child1} =
        Goals.create_goal(%{title: "C1", project_id: project.id, parent_id: root.id})

      {:ok, _child2} =
        Goals.create_goal(%{title: "C2", project_id: project.id, parent_id: root.id})

      {:ok, _grandchild} =
        Goals.create_goal(%{title: "GC1", project_id: project.id, parent_id: child1.id})

      descendants = Goals.get_descendants(root.id)
      assert length(descendants) == 3
    end
  end
end
