defmodule Cympho.SubissueCompletionTest do
  use Cympho.DataCase, async: true
  alias Cympho.Issues

  setup do
    company = insert(:company)
    project = insert(:project, company_id: company.id)
    {:ok, company: company, project: project}
  end

  describe "subissue auto-completion" do
    test "parent auto-completes when all children are done", %{project: project} do
      parent = insert(:issue, project_id: project.id, status: :in_progress)
      child1 = insert(:issue, project_id: project.id, parent_id: parent.id, status: :in_progress)
      child2 = insert(:issue, project_id: project.id, parent_id: parent.id, status: :in_progress)

      {:ok, _} = Issues.transition_issue(child1, :done)
      # Parent should NOT be done yet — child2 still in_progress
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status != :done

      {:ok, _} = Issues.transition_issue(child2, :done)
      # Now parent should auto-complete
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status == :done
    end

    test "parent without children completing does not crash", %{project: project} do
      issue = insert(:issue, project_id: project.id, status: :in_progress)
      assert {:ok, _} = Issues.transition_issue(issue, :done)
    end

    test "parent does not complete if some children are still active", %{project: project} do
      parent = insert(:issue, project_id: project.id, status: :in_progress)
      child1 = insert(:issue, project_id: project.id, parent_id: parent.id, status: :done)
      _child2 = insert(:issue, project_id: project.id, parent_id: parent.id, status: :in_progress)

      # Re-transition child1 (already done) — parent should NOT complete
      parent = Repo.get(Cympho.Issues.Issue, parent.id)
      assert parent.status != :done
    end
  end

  describe "issue-goal linking" do
    test "issue can reference a goal", %{project: project} do
      {:ok, goal} = Cympho.Goals.create_goal(%{title: "Sprint 1", project_id: project.id})
      issue = insert(:issue, project_id: project.id, goal_id: goal.id)

      assert issue.goal_id == goal.id
    end
  end
end
