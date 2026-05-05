defmodule Cympho.Skills.Sandbox.AuditTest do
  use Cympho.DataCase
  alias Cympho.Skills.Sandbox.Audit
  alias Cympho.{Agents, Companies, Plugins}

  test "logs successful authorization" do
    {:ok, company} =
      Companies.create_company(%{name: "Test Company", slug: "test-#{System.unique_integer()}"})

    {:ok, agent} = Agents.create_agent(%{name: "Agent", role: :engineer, company_id: company.id})

    Plugins.create_plugin(%{
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

    Plugins.create_plugin(%{
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

    Plugins.create_plugin(%{
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
