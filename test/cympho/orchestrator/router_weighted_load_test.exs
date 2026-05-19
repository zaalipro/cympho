defmodule Cympho.Orchestrator.RouterWeightedLoadTest do
  use Cympho.DataCase, async: false

  alias Cympho.{Agents, Companies, Issues}
  alias Cympho.Orchestrator.Dispatcher.Router

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Router Load Co #{System.unique_integer([:positive])}",
        slug: "router-load-#{System.unique_integer([:positive])}"
      })

    {:ok, project} =
      Cympho.Projects.create_project(%{
        name: "P",
        prefix: "RWL",
        company_id: company.id
      })

    {:ok, alice} =
      Agents.create_agent(%{
        name: "alice",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    {:ok, bob} =
      Agents.create_agent(%{
        name: "bob",
        role: :engineer,
        status: :idle,
        company_id: company.id
      })

    %{company: company, project: project, alice: alice, bob: bob}
  end

  test "select_agent prefers the engineer with smaller estimated load", %{
    alice: alice,
    bob: bob,
    company: company,
    project: project
  } do
    # Alice has one big task (180 min); Bob has two small tasks (20 + 30 = 50 min).
    issue!(alice, project, company, 180, "alice big")
    issue!(bob, project, company, 20, "bob small 1")
    issue!(bob, project, company, 30, "bob small 2")

    # Sanity: both agents have one or two assignments.
    assert Agents.count_active_assignments(alice.id) == 1
    assert Agents.count_active_assignments(bob.id) == 2

    # Despite Bob having more raw assignments, Alice has more *minutes*.
    # Router picks Bob (lower minutes).
    eligible = [alice, bob]
    {:ok, selected} = Router.select_agent(:engineer, eligible)
    assert selected.id == bob.id
  end

  test "select_agent falls back to count + name when estimates tie", %{
    alice: alice,
    bob: bob
  } do
    # Both empty. Tie on load — alphabetical tie-breaker picks alice.
    {:ok, selected} = Router.select_agent(:engineer, [alice, bob])
    assert selected.id == alice.id
  end

  defp issue!(agent, project, company, minutes, title) do
    {:ok, issue} =
      Issues.create_issue(%{
        title: title,
        status: :in_progress,
        priority: :medium,
        company_id: company.id,
        project_id: project.id,
        assignee_id: agent.id,
        monitor_state: %{"estimated_minutes" => minutes}
      })

    issue
  end
end
