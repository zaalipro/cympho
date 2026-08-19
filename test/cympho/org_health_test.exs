defmodule Cympho.OrgHealthTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.{Issues, OrgHealth}

  describe "snapshot/1" do
    test "detects missing core roles and detached reporting lines" do
      company = create_company("critical")
      other_company = create_company("other")
      other_parent = create_agent(other_company, "External CTO", :cto)

      detached_agent = create_agent(company, "Detached Engineer", :engineer)

      # Simulate legacy-corrupt data without weakening the production changeset,
      # which correctly rejects cross-company reporting lines.
      {1, nil} =
        Repo.update_all(
          from(agent in Cympho.Agents.Agent, where: agent.id == ^detached_agent.id),
          set: [parent_id: other_parent.id]
        )

      snapshot = OrgHealth.snapshot(company.id)

      assert snapshot.level == :critical
      assert snapshot.label == "Org risk"
      assert snapshot.metrics.missing_roles == 2
      assert snapshot.metrics.detached_agents == 1
      assert snapshot.missing_roles == [:ceo, :cto]
      assert [%{name: "Detached Engineer"}] = snapshot.detached_agents
      assert Enum.any?(snapshot.recommendations, &(&1.label == "Fill role coverage"))
      assert Enum.any?(snapshot.recommendations, &(&1.label == "Reattach reports"))
    end

    test "detects overloaded managers and unhealthy agents" do
      company = create_company("warning")
      _ceo = create_agent(company, "CEO", :ceo)
      cto = create_agent(company, "CTO", :cto)

      for index <- 1..7 do
        create_agent(company, "Engineer #{index}", :engineer, parent_id: cto.id)
      end

      create_agent(company, "Offline Designer", :designer,
        parent_id: cto.id,
        status: :offline,
        health_status: :degraded
      )

      snapshot = OrgHealth.snapshot(company.id)

      assert snapshot.level == :warning
      assert snapshot.metrics.overloaded_managers == 1
      assert snapshot.metrics.inactive_agents == 1
      assert snapshot.metrics.degraded_agents == 1
      assert [%{name: "CTO", direct_reports: 8}] = snapshot.overloaded_managers
      assert Enum.any?(snapshot.recommendations, &(&1.label == "Split manager span"))
      assert Enum.any?(snapshot.recommendations, &(&1.label == "Restore inactive agents"))
      assert Enum.any?(snapshot.recommendations, &(&1.label == "Repair adapter health"))
    end

    test "recommends staffing roles that have open issue demand" do
      company = create_company("demand")
      ceo = create_agent(company, "CEO", :ceo)
      cto = create_agent(company, "CTO", :cto, parent_id: ceo.id)
      create_agent(company, "Engineer", :engineer, parent_id: cto.id)

      marketing_issue = create_issue(company, "Plan SEO launch campaign", status: :todo)
      create_issue(company, "Write customer support FAQ", status: :blocked)
      create_issue(company, "Shipped campaign", status: :done, assigned_role: "marketing")

      snapshot = OrgHealth.snapshot(company.id)

      assert snapshot.level == :warning
      assert snapshot.metrics.missing_roles == 0
      assert snapshot.metrics.role_demand_gaps == 2
      assert snapshot.metrics.unstaffed_role_issues == 2

      assert [
               %{role: :customer_support, open_issues: 1},
               %{role: :marketer, open_issues: 1}
             ] = snapshot.role_demand_gaps

      marketer_gap = Enum.find(snapshot.role_demand_gaps, &(&1.role == :marketer))

      assert [
               %{
                 id: id,
                 identifier: identifier,
                 title: "Plan SEO launch campaign"
               }
             ] = marketer_gap.examples

      assert id == marketing_issue.id
      assert identifier == marketing_issue.identifier

      assert Enum.any?(snapshot.recommendations, fn recommendation ->
               recommendation.label == "Staff queued work" and
                 recommendation.detail =~ "Customer Support (1 issue)" and
                 recommendation.detail =~ "Marketer (1 issue)"
             end)
    end
  end

  defp create_company(label) do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Org Health #{label} #{unique}",
        slug: "org-health-#{label}-#{unique}"
      })

    company
  end

  defp create_agent(company, name, role, attrs \\ []) do
    attrs =
      attrs
      |> Map.new()
      |> Map.merge(%{
        name: name,
        role: role,
        status: Keyword.get(attrs, :status, :idle),
        adapter: :process,
        health_status: Keyword.get(attrs, :health_status, :healthy),
        company_id: company.id
      })

    {:ok, agent} = Agents.create_agent(attrs)
    agent
  end

  defp create_issue(company, title, attrs) do
    attrs = Map.new(attrs)

    attrs =
      attrs
      |> Map.merge(%{
        title: title,
        company_id: company.id,
        status: Map.get(attrs, :status, :todo),
        assigned_role: Map.get(attrs, :assigned_role)
      })

    {:ok, issue} = Issues.create_issue(attrs)
    issue
  end
end
