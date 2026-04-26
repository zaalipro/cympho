defmodule Cympho.SubissueCompletionTest do
  use Cympho.DataCase, async: true
  alias Cympho.Issues

  setup do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Test Co",
        slug: "sub-#{abs(System.unique_integer())}"
      })

    prefix = for _ <- 1..4, into: "", do: <<Enum.random(?A..?Z)>>

    {:ok, project} =
      Cympho.Projects.create_project(%{name: "Proj", prefix: prefix, company_id: company.id})

    {:ok, company: company, project: project}
  end

  defp transition_to_done(issue) do
    {:ok, issue} = Issues.transition_issue(issue, :in_review)
    {:ok, issue} = Issues.transition_issue(issue, :done)
    {:ok, issue}
  end

  describe "subissue auto-completion" do
    test "parent auto-completes when all children are done", %{project: project} do
      {:ok, parent} =
        Issues.create_issue(%{title: "Parent", project_id: project.id, status: :in_progress})

      {:ok, child1} =
        Issues.create_issue(%{
          title: "C1",
          project_id: project.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "C2",
          project_id: project.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, _} = transition_to_done(child1)
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status != :done

      {:ok, _} = transition_to_done(child2)
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status == :done
    end

    test "parent without children completing does not crash", %{project: project} do
      {:ok, issue} =
        Issues.create_issue(%{title: "Solo", project_id: project.id, status: :in_progress})

      assert {:ok, _} = transition_to_done(issue)
    end

    test "parent does not complete if some children are still active", %{project: project} do
      {:ok, parent} =
        Issues.create_issue(%{title: "Parent", project_id: project.id, status: :in_progress})

      {:ok, child1} =
        Issues.create_issue(%{
          title: "C1",
          project_id: project.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, _child2} =
        Issues.create_issue(%{
          title: "C2",
          project_id: project.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, _} = transition_to_done(child1)
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status != :done
    end
  end

  describe "issue-goal linking" do
    test "issue can reference a goal", %{project: project} do
      {:ok, goal} = Cympho.Goals.create_goal(%{title: "Sprint 1", project_id: project.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "Task", project_id: project.id, goal_id: goal.id})

      assert issue.goal_id == goal.id
    end
  end
end
