defmodule Cympho.MultiTenancyPr1Test do
  @moduledoc """
  PR 1 (REQ-001) multi-tenancy hardening: plugin host services, workspace
  listing, role lookups, and goal access must never cross the company
  boundary.
  """
  use Cympho.DataCase, async: true

  alias Cympho.{Agents, Companies, Goals, Issues, Projects, Workspaces}
  alias Cympho.Plugins.HostServices

  setup do
    u = System.unique_integer([:positive])
    {:ok, company_a} = Companies.create_company(%{name: "A#{u}", slug: "a-#{u}"})
    {:ok, company_b} = Companies.create_company(%{name: "B#{u}", slug: "b-#{u}"})
    %{a: company_a, b: company_b, u: u}
  end

  describe "HostServices issue access (AC-001)" do
    test "get_issue returns own-company issues and not-found for foreign ones", %{a: a, b: b} do
      {:ok, issue} = Issues.create_issue(%{title: "secret", company_id: a.id, status: :todo})
      caps = ["read:issues"]

      assert {:ok, %{id: id}} = HostServices.get_issue(a.id, issue.id, caps)
      assert id == issue.id
      assert {:error, :not_found} = HostServices.get_issue(b.id, issue.id, caps)
      assert {:error, :unauthorized} = HostServices.get_issue(a.id, issue.id, [])
    end

    test "list_issues only returns the caller's company issues", %{a: a, b: b} do
      {:ok, _} = Issues.create_issue(%{title: "a-only", company_id: a.id, status: :todo})
      {:ok, _} = Issues.create_issue(%{title: "b-only", company_id: b.id, status: :todo})

      a_issues = HostServices.list_issues(a.id, %{}, ["read:issues"])

      assert Enum.all?(a_issues, &(&1.company_id == a.id))
      assert Enum.any?(a_issues, &(&1.title == "a-only"))
      refute Enum.any?(a_issues, &(&1.title == "b-only"))
    end

    test "get_agent returns own-company agents and not-found for foreign ones", %{a: a, b: b} do
      {:ok, agent} = Agents.create_agent(%{name: "ag", role: :engineer, company_id: a.id})

      assert {:ok, %{id: id}} = HostServices.get_agent(a.id, agent.id, ["read:agents"])
      assert id == agent.id
      assert {:error, :not_found} = HostServices.get_agent(b.id, agent.id, ["read:agents"])
    end
  end

  describe "Workspaces.list_project_workspaces_for_company/1 (AC-003)" do
    test "returns [] for a nil company_id (no fail-open to all rows)" do
      assert Workspaces.list_project_workspaces_for_company(nil) == []
    end

    test "returns only the company's workspaces", %{a: a, b: b, u: u} do
      {:ok, project_a} =
        Projects.create_project(%{name: "PA#{u}", prefix: "PAAAAA", company_id: a.id})

      {:ok, _} =
        Workspaces.create_project_workspace(%{
          name: "wsa",
          company_id: a.id,
          project_id: project_a.id
        })

      {:ok, project_b} =
        Projects.create_project(%{name: "PB#{u}", prefix: "PBBBBB", company_id: b.id})

      {:ok, _} =
        Workspaces.create_project_workspace(%{
          name: "wsb",
          company_id: b.id,
          project_id: project_b.id
        })

      a_list = Workspaces.list_project_workspaces_for_company(a.id)

      assert Enum.all?(a_list, &(&1.company_id == a.id))
      assert length(a_list) == 1
    end
  end

  describe "Agents role lookups are company-scoped (AC-009)" do
    test "list_agents_by_role/2 and get_idle_agent_by_role/2 never cross companies", %{
      a: a,
      b: b
    } do
      {:ok, _} =
        Agents.create_agent(%{name: "ea", role: :engineer, status: :idle, company_id: a.id})

      {:ok, _} =
        Agents.create_agent(%{name: "eb", role: :engineer, status: :idle, company_id: b.id})

      a_engineers = Agents.list_agents_by_role(:engineer, a.id)
      assert Enum.all?(a_engineers, &(&1.company_id == a.id))
      assert length(a_engineers) == 1

      idle = Agents.get_idle_agent_by_role(:engineer, a.id)
      assert idle.company_id == a.id
    end
  end

  describe "Goals.get_company_goal/2 (AC-005)" do
    test "returns the goal under its company; not-found from another", %{a: a, b: b} do
      {:ok, goal} = Goals.create_goal(%{title: "g", company_id: a.id})

      assert {:ok, %{id: id}} = Goals.get_company_goal(a.id, goal.id)
      assert id == goal.id
      assert {:error, :not_found} = Goals.get_company_goal(b.id, goal.id)
    end
  end
end
