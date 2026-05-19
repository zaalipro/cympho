defmodule Cympho.Decisions.ExecutorTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Companies, Issues, Projects, Repo}
  alias Cympho.Decisions.Decision
  alias Cympho.Decisions.Executor

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Exec Co #{System.unique_integer([:positive])}",
        slug: "exec-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Projects.create_project(%{
        name: "P",
        prefix: "EXC",
        company_id: company.id
      })

    %{company: company, project: project}
  end

  describe "execute/1" do
    test "cancel_project archives the project + cancels open issues", %{
      company: company,
      project: project
    } do
      {:ok, i1} =
        Issues.create_issue(%{
          title: "Task 1",
          status: :todo,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      {:ok, i2} =
        Issues.create_issue(%{
          title: "Task 2",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "cancel_project:" <> project.id,
        decision_type: "strategic",
        outcome: "cancelled",
        reasoning: "pivot"
      }

      assert :ok = Executor.execute(decision)

      assert Issues.get_issue!(i1.id).status == :cancelled
      assert Issues.get_issue!(i2.id).status == :cancelled
      assert Repo.get!(Cympho.Projects.Project, project.id).status == :archived
    end

    test "pause_engineer flips governance_status to paused", %{company: company} do
      {:ok, eng} =
        Agents.create_agent(%{
          name: "Bob",
          role: :engineer,
          status: :idle,
          company_id: company.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "pause_engineer:" <> eng.id,
        decision_type: "governance",
        outcome: "paused",
        reasoning: "Excessive failures"
      }

      assert :ok = Executor.execute(decision)

      reloaded = Repo.get!(Cympho.Agents.Agent, eng.id)
      assert reloaded.governance_status == "paused"
      assert reloaded.pause_reason =~ "Excessive failures"
    end

    test "cancel_issue terminates a specific issue", %{company: company, project: project} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Doomed",
          status: :in_progress,
          priority: :medium,
          company_id: company.id,
          project_id: project.id
        })

      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "cancel_issue:" <> issue.id,
        decision_type: "strategic",
        outcome: "cancelled",
        reasoning: "no longer needed"
      }

      assert :ok = Executor.execute(decision)
      assert Issues.get_issue!(issue.id).status == :cancelled
    end

    test "unknown decision_key is a no-op", %{company: company} do
      decision = %Decision{
        id: Ecto.UUID.generate(),
        company_id: company.id,
        decision_key: "make_breakfast",
        decision_type: "strategic"
      }

      assert :ok = Executor.execute(decision)
    end
  end
end
