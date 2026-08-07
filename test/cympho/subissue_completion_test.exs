defmodule Cympho.SubissueCompletionTest do
  use Cympho.DataCase, async: true
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Wakes
  alias Cympho.Repo

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

    test "soft-blocked non-CEO parent reopens to todo after children done", %{
      company: company,
      project: project
    } do
      {:ok, cto} =
        Cympho.Agents.create_agent(%{
          name: "CTO",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "CTO parent",
          project_id: project.id,
          company_id: company.id,
          status: :blocked,
          assignee_id: nil,
          assigned_role: "cto",
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => cto.id
          }
        })

      {:ok, child1} =
        Issues.create_issue(%{
          title: "C1",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "C2",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, _} = transition_to_done(child1)
      {:ok, _} = transition_to_done(child2)

      parent = Issues.get_issue!(parent.id)
      assert parent.status == :todo
      refute parent.status == :done
      assert parent.assignee_id == cto.id

      comments = Comments.list_comments(parent.id)

      assert Enum.any?(comments, fn c ->
               c.body =~ "Reopened after child completion"
             end)

      wakes = Wakes.list_issue_wakes(parent.id)

      assert Enum.any?(wakes, fn w ->
               w.reason == "issue_children_completed" and w.status in ["pending", "running"]
             end)
    end

    test "soft-blocked CEO root goes to in_review after child done", %{
      company: company,
      project: project
    } do
      {:ok, ceo} =
        Cympho.Agents.create_agent(%{
          name: "CEO",
          role: :ceo,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "CEO root",
          project_id: project.id,
          company_id: company.id,
          status: :blocked,
          assignee_id: nil,
          assigned_role: "ceo",
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => ceo.id
          }
        })

      {:ok, child} =
        Issues.create_issue(%{
          title: "Only child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :in_progress
        })

      {:ok, _} = transition_to_done(child)

      parent = Issues.get_issue!(parent.id)
      assert parent.status == :in_review
      refute parent.status == :done

      comments = Comments.list_comments(parent.id)

      assert Enum.any?(comments, fn c ->
               c.body =~ "Subtree complete — awaiting CEO sign-off"
             end)
    end

    test "cancelled last child reopens soft-blocked non-CEO parent", %{
      company: company,
      project: project
    } do
      {:ok, cto} =
        Cympho.Agents.create_agent(%{
          name: "CTO Cancel",
          role: :cto,
          status: :idle,
          company_id: company.id
        })

      {:ok, parent} =
        Issues.create_issue(%{
          title: "CTO parent cancel path",
          project_id: project.id,
          company_id: company.id,
          status: :blocked,
          assignee_id: nil,
          assigned_role: "cto",
          monitor_state: %{
            "decomposition_parked" => true,
            "decomposition_owner_id" => cto.id
          }
        })

      {:ok, child1} =
        Issues.create_issue(%{
          title: "Done child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :done
        })

      {:ok, child2} =
        Issues.create_issue(%{
          title: "Cancel child",
          project_id: project.id,
          company_id: company.id,
          parent_id: parent.id,
          status: :todo
        })

      assert child1.status == :done
      {:ok, _} = Issues.transition_issue(child2, :cancelled)

      parent = Issues.get_issue!(parent.id)
      assert parent.status == :todo
      refute parent.status == :done

      comments = Comments.list_comments(parent.id)

      assert Enum.any?(comments, fn c ->
               c.body =~ "Reopened after child completion"
             end)
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
