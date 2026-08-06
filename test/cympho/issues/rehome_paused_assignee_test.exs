defmodule Cympho.Issues.RehomePausedAssigneeTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.RehomePaused
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Rehome Co #{System.unique_integer([:positive])}",
        slug: "rehome-#{System.unique_integer([:positive])}"
      })

    {:ok, manager} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "CTO",
        role: :cto,
        status: :idle,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Engineer",
        role: :engineer,
        status: :idle,
        parent_id: manager.id,
        adapter: :process,
        config: %{"command" => "echo"}
      })

    %{company: company, manager: manager, agent: agent}
  end

  describe "list_rehomeable_issues/1" do
    test "returns only non-terminal assigned issues", %{company: company, agent: agent} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, todo} =
        Issues.create_issue(%{
          title: "Todo",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      {:ok, _done} =
        Issues.create_issue(%{
          title: "Done",
          company_id: company.id,
          status: :done,
          assignee_id: agent.id
        })

      {:ok, _in_progress} =
        Issues.create_issue(%{
          title: "In progress",
          company_id: company.id,
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now
        })

      ids = agent.id |> RehomePaused.list_rehomeable_issues() |> Enum.map(& &1.id)
      assert todo.id in ids
      assert length(ids) == 2
    end
  end

  describe "rehome_for_paused_agent/2" do
    test "clears assignees, cancels wakes, wakes manager", %{
      company: company,
      manager: manager,
      agent: agent
    } do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok, review} =
        Issues.create_issue(%{
          title: "In review",
          company_id: company.id,
          status: :in_review,
          assignee_id: agent.id
        })

      {:ok, active} =
        Issues.create_issue(%{
          title: "Active",
          company_id: company.id,
          status: :in_progress,
          assignee_id: agent.id,
          checked_out_at: now
        })

      {:ok, blocked} =
        Issues.create_issue(%{
          title: "Blocked",
          company_id: company.id,
          status: :blocked,
          assignee_id: agent.id
        })

      {:ok, wake} =
        Wakes.do_wake_agent(agent.id, active.id, "manual_dispatch", "system", nil, %{})

      assert {:ok, summary} =
               RehomePaused.rehome_for_paused_agent(agent, reason: "budget pause")

      assert length(summary.rehomed) == 3
      assert summary.cancelled_wakes >= 1
      assert summary.manager_wakes >= 1

      reloaded_review = Issues.get_issue!(review.id)
      reloaded_active = Issues.get_issue!(active.id)
      reloaded_blocked = Issues.get_issue!(blocked.id)

      assert reloaded_review.assignee_id == nil
      assert reloaded_review.status == :in_review

      assert reloaded_active.assignee_id == nil
      assert reloaded_active.status == :todo
      assert reloaded_active.checked_out_at == nil
      assert reloaded_active.checkout_run_id == nil

      assert reloaded_blocked.assignee_id == nil
      assert reloaded_blocked.status == :blocked

      assert Repo.get!(AgentWake, wake.id).status == "cancelled"

      manager_wakes =
        Repo.all(
          from w in AgentWake,
            where:
              w.agent_id == ^manager.id and w.reason == "escalation_from_subordinate" and
                w.status == "pending"
        )

      assert length(manager_wakes) == 3
      assert Enum.all?(manager_wakes, &(&1.metadata["rehome"] == true))
      assert Enum.all?(manager_wakes, &(&1.metadata["paused_agent_id"] == agent.id))
    end

    test "is a no-op when agent has no assigned work", %{agent: agent} do
      assert {:ok, summary} = RehomePaused.rehome_for_paused_agent(agent)
      assert summary.rehomed == []
      assert summary.manager_wakes == 0
    end

    test "skips waking a paused manager and still clears assignee", %{
      company: company,
      manager: manager,
      agent: agent
    } do
      {:ok, todo} =
        Issues.create_issue(%{
          title: "Todo",
          company_id: company.id,
          status: :todo,
          assignee_id: agent.id
        })

      # Mark manager dead without going through pause rehome.
      {:ok, _} =
        manager
        |> Ecto.Changeset.change(%{status: :paused, governance_status: "paused"})
        |> Repo.update()

      assert {:ok, summary} = RehomePaused.rehome_for_paused_agent(agent, reason: "pause")
      assert length(summary.rehomed) == 1
      assert summary.manager_wakes == 0
      assert Issues.get_issue!(todo.id).assignee_id == nil
    end
  end
end
