defmodule Cympho.Skills.Sandbox.AuditTest do
  use Cympho.DataCase
  alias Cympho.Skills.Sandbox.Audit
  alias Cympho.{Agents, Companies, Skills}

  test "role hierarchy is a map of the five known roles" do
    assert Cympho.Skills.Sandbox.role_hierarchy() == %{
             cto: 5,
             ceo: 4,
             engineer: 3,
             product_manager: 2,
             designer: 1
           }

    assert Cympho.Skills.Sandbox.get_role_level(:cto) == 5
    assert Cympho.Skills.Sandbox.get_role_level(:ceo) == 4
    assert Cympho.Skills.Sandbox.get_role_level(:engineer) == 3
  end

  test "logs successful authorization" do
    {:ok, company} =
      Companies.create_company(%{name: "Test Company", slug: "test-#{System.unique_integer()}"})

    {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :engineer, company_id: company.id})

    Skills.create_plugin(%{
      identifier: "system.sandbox",
      name: "Sandbox",
      version: "1.0.0",
      company_id: company.id
    })

    :ok = Audit.log_decision(agent.id, :engineer, "code.write", :ok)
    logs = Audit.logs_for_agent(agent.id)
    assert length(logs) > 0
    assert List.first(logs).level == "info"
  end

  test "logs denied authorization" do
    {:ok, company} =
      Companies.create_company(%{name: "Test Company", slug: "test-#{System.unique_integer()}"})

    {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :designer, company_id: company.id})

    Skills.create_plugin(%{
      identifier: "system.sandbox",
      name: "Sandbox",
      version: "1.0.0",
      company_id: company.id
    })

    :ok =
      Audit.log_decision(
        agent.id,
        :designer,
        "system.admin",
        {:error, :unauthorized, "requires cto"}
      )

    logs = Audit.logs_for_agent(agent.id)
    assert List.first(logs).level == "warn"
  end

  test "denied_attempts returns only denied attempts" do
    {:ok, company} =
      Companies.create_company(%{name: "Test Company", slug: "test-#{System.unique_integer()}"})

    {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :designer, company_id: company.id})

    Skills.create_plugin(%{
      identifier: "system.sandbox",
      name: "Sandbox",
      version: "1.0.0",
      company_id: company.id
    })

    Audit.log_decision(
      agent.id,
      :designer,
      "system.admin",
      {:error, :unauthorized, "requires cto"}
    )

    denied_logs = Audit.denied_attempts()
    assert length(denied_logs) >= 1
  end
end
