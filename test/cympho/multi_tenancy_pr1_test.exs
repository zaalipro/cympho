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

    test "create_issue overrides a forged atom-key company scope", %{a: a, b: b, u: u} do
      title = "plugin-atom-scope-#{u}"

      assert {:ok, issue} =
               HostServices.create_issue(
                 a.id,
                 %{
                   title: title,
                   company_id: b.id,
                   status: :todo,
                   skip_auto_assign: true
                 },
                 ["write:issues"]
               )

      assert issue.company_id == a.id
      assert Enum.any?(HostServices.list_issues(a.id, %{}, ["read:issues"]), &(&1.id == issue.id))
      refute Enum.any?(HostServices.list_issues(b.id, %{}, ["read:issues"]), &(&1.id == issue.id))
    end

    test "create_issue overrides a forged string-key company scope", %{a: a, b: b, u: u} do
      title = "plugin-string-scope-#{u}"

      assert {:ok, issue} =
               HostServices.create_issue(
                 a.id,
                 %{
                   "title" => title,
                   "company_id" => b.id,
                   "status" => "todo",
                   "skip_auto_assign" => true
                 },
                 ["write:issues"]
               )

      assert issue.company_id == a.id
      assert Enum.any?(HostServices.list_issues(a.id, %{}, ["read:issues"]), &(&1.id == issue.id))
      refute Enum.any?(HostServices.list_issues(b.id, %{}, ["read:issues"]), &(&1.id == issue.id))
    end

    test "update_issue loads via company scope and updates own-company issues", %{a: a, u: u} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "update-me-#{u}",
          company_id: a.id,
          status: :todo,
          skip_auto_assign: true
        })

      assert {:ok, updated} =
               HostServices.update_issue(
                 a.id,
                 issue.id,
                 %{title: "updated-#{u}"},
                 ["write:issues"]
               )

      assert updated.id == issue.id
      assert updated.company_id == a.id
      assert updated.title == "updated-#{u}"
    end

    test "update_issue is not-found for foreign company issues", %{a: a, b: b, u: u} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "b-secret-#{u}",
          company_id: b.id,
          status: :todo,
          skip_auto_assign: true
        })

      assert {:error, :not_found} =
               HostServices.update_issue(
                 a.id,
                 issue.id,
                 %{title: "stolen-#{u}"},
                 ["write:issues"]
               )

      reloaded = Issues.get_issue!(issue.id)
      assert reloaded.title == "b-secret-#{u}"
      assert reloaded.company_id == b.id
    end

    test "update_issue strips forged company_id from attrs (atom and string keys)", %{
      a: a,
      b: b,
      u: u
    } do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "keep-tenant-#{u}",
          company_id: a.id,
          status: :todo,
          skip_auto_assign: true
        })

      assert {:ok, updated} =
               HostServices.update_issue(
                 a.id,
                 issue.id,
                 %{title: "atom-forged-#{u}", company_id: b.id},
                 ["write:issues"]
               )

      assert updated.company_id == a.id
      assert updated.title == "atom-forged-#{u}"

      assert {:ok, updated2} =
               HostServices.update_issue(
                 a.id,
                 issue.id,
                 %{"title" => "string-forged-#{u}", "company_id" => b.id},
                 ["write:issues"]
               )

      assert updated2.company_id == a.id
      assert updated2.title == "string-forged-#{u}"
    end

    test "update_issue requires write:issues and a binary company scope", %{a: a, u: u} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "caps-#{u}",
          company_id: a.id,
          status: :todo,
          skip_auto_assign: true
        })

      assert {:error, :unauthorized} =
               HostServices.update_issue(a.id, issue.id, %{title: "nope"}, [])

      assert {:error, :invalid_company_scope} =
               HostServices.update_issue(nil, issue.id, %{title: "nope"}, ["write:issues"])
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

  describe "fail-closed company_id on checkout / runtime / actions (ot-tenancy-fail-closed)" do
    test "checkout rejects when issue company_id is nil", %{a: a} do
      {:ok, agent} =
        Agents.create_agent(%{name: "scoped", role: :engineer, company_id: a.id})

      {:ok, issue} = Issues.create_issue(%{title: "unscoped issue", status: :todo})

      assert is_nil(issue.company_id)
      assert {:error, :company_mismatch} = Issues.checkout_issue(issue, agent)
    end

    test "checkout rejects when agent company_id is nil", %{a: a} do
      {:ok, agent} = Agents.create_agent(%{name: "unscoped", role: :engineer})

      {:ok, issue} =
        Issues.create_issue(%{title: "scoped issue", status: :todo, company_id: a.id})

      assert is_nil(agent.company_id)
      assert {:error, :company_mismatch} = Issues.checkout_issue(issue, agent)
    end

    test "checkout rejects unequal company_ids", %{a: a, b: b} do
      {:ok, agent} =
        Agents.create_agent(%{name: "a-agent", role: :engineer, company_id: a.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "b-issue", status: :todo, company_id: b.id})

      assert {:error, :company_mismatch} = Issues.checkout_issue(issue, agent)
    end

    test "checkout allows matching company_ids", %{a: a} do
      {:ok, agent} =
        Agents.create_agent(%{name: "match", role: :engineer, company_id: a.id})

      {:ok, issue} =
        Issues.create_issue(%{title: "match issue", status: :todo, company_id: a.id})

      assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)
      assert checked_out.assignee_id == agent.id
      assert checked_out.company_id == a.id
    end

    test "Runtime.preflight rejects nil or mismatched company_id", %{a: a, b: b} do
      {:ok, agent_a} =
        Agents.create_agent(%{
          name: "rt-a",
          role: :engineer,
          status: :idle,
          company_id: a.id,
          adapter: :process,
          config: %{"command" => "echo", "repo_capable" => true}
        })

      {:ok, issue_nil} = Issues.create_issue(%{title: "rt-nil", status: :todo})

      {:ok, issue_b} =
        Issues.create_issue(%{title: "rt-b", status: :todo, company_id: b.id})

      {:ok, issue_a} =
        Issues.create_issue(%{title: "rt-a", status: :todo, company_id: a.id})

      assert {:error, :company_mismatch} = Cympho.Runtime.preflight(issue_nil, agent_a)
      assert {:error, :company_mismatch} = Cympho.Runtime.preflight(issue_b, agent_a)
      # Matching company_id is not a mismatch; other preflight gates may still apply.
      refute match?(
               {:error, :company_mismatch},
               Cympho.Runtime.preflight(issue_a, agent_a)
             )
    end

    test "AgentActions.execute rejects nil or mismatched company_id", %{a: a, b: b} do
      {:ok, agent_a} =
        Agents.create_agent(%{name: "act-a", role: :engineer, company_id: a.id})

      {:ok, issue_nil} = Issues.create_issue(%{title: "act-nil", status: :todo})

      {:ok, issue_b} =
        Issues.create_issue(%{title: "act-b", status: :todo, company_id: b.id})

      actions = [%{"type" => "comment", "body" => "nope"}]

      assert {:error, :cross_company} =
               Cympho.AgentActions.execute(issue_nil, agent_a, actions)

      assert {:error, :cross_company} =
               Cympho.AgentActions.execute(issue_b, agent_a, actions)
    end
  end
end
