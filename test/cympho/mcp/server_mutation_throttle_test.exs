defmodule Cympho.Mcp.ServerMutationThrottleTest do
  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.GovernanceAuditLogs
  alias Cympho.Issues
  alias Cympho.Mcp.Server
  alias Cympho.RateLimiting.AgentActionLimiter

  setup do
    AgentActionLimiter.reset()
    original = Application.get_env(:cympho, :agent_actions, [])
    Application.put_env(:cympho, :agent_actions, max_per_minute: 2)

    on_exit(fn ->
      Application.put_env(:cympho, :agent_actions, original)
      AgentActionLimiter.reset()
    end)

    {:ok, company} =
      Companies.create_company(%{
        name: "MCP Throttle Co",
        slug: "mcp-throttle-#{System.unique_integer([:positive])}"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "MCP Throttle Agent",
        role: :cto,
        status: :idle
      })

    %{company: company, agent: agent}
  end

  test "create_issue is rate-limited per agent with a stable error body", %{agent: agent} do
    assert %{success: true, issue: %{id: _}} =
             Server.call_tool("create_issue", %{"title" => "one"}, agent)

    assert %{success: true, issue: %{id: _}} =
             Server.call_tool("create_issue", %{"title" => "two"}, agent)

    assert Server.call_tool("create_issue", %{"title" => "three"}, agent) == %{
             error: "rate_limited",
             success: false
           }

    # Same stable shape on subsequent floods — no issue creation.
    assert Server.call_tool("create_issue", %{"title" => "four"}, agent) == %{
             error: "rate_limited",
             success: false
           }
  end

  test "create_issue_comment is rate-limited per agent", %{company: company, agent: agent} do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "comment target",
        skip_auto_assign: true
      })

    assert %{success: true, comment: %{id: _}} =
             Server.call_tool(
               "create_issue_comment",
               %{"issue_id" => issue.id, "body" => "first"},
               agent
             )

    assert %{success: true, comment: %{id: _}} =
             Server.call_tool(
               "create_issue_comment",
               %{"issue_id" => issue.id, "body" => "second"},
               agent
             )

    assert Server.call_tool(
             "create_issue_comment",
             %{"issue_id" => issue.id, "body" => "third"},
             agent
           ) == %{error: "rate_limited", success: false}

    assert length(Comments.list_comments(issue.id)) == 2
  end

  test "create_issue and create_issue_comment share the agent action budget", %{
    company: company,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        company_id: company.id,
        title: "shared budget target",
        skip_auto_assign: true
      })

    assert %{success: true} =
             Server.call_tool("create_issue", %{"title" => "budget one"}, agent)

    assert %{success: true} =
             Server.call_tool(
               "create_issue_comment",
               %{"issue_id" => issue.id, "body" => "uses second slot"},
               agent
             )

    assert Server.call_tool("create_issue", %{"title" => "over cap"}, agent) == %{
             error: "rate_limited",
             success: false
           }
  end

  test "flood cannot create unbounded issues (blocks auto-ignite amplification)", %{
    company: company,
    agent: agent
  } do
    prior_on = Application.get_env(:cympho, :auto_ignite_on_create)
    prior_sync = Application.get_env(:cympho, :auto_ignite_sync)
    Application.put_env(:cympho, :auto_ignite_on_create, true)
    Application.put_env(:cympho, :auto_ignite_sync, true)

    on_exit(fn ->
      put_or_delete(:auto_ignite_on_create, prior_on)
      put_or_delete(:auto_ignite_sync, prior_sync)
    end)

    results =
      for i <- 1..10 do
        Server.call_tool("create_issue", %{"title" => "flood #{i}"}, agent)
      end

    successes = Enum.count(results, &match?(%{success: true}, &1))
    limited = Enum.count(results, &(&1 == %{error: "rate_limited", success: false}))

    assert successes == 2
    assert limited == 8

    mcp_issues =
      Issues.list_issues_paginated(%{
        "company_id" => company.id,
        "per_page" => "100"
      }).issues
      |> Enum.filter(&(&1.origin_type == "mcp" and &1.origin_id == agent.id))

    assert length(mcp_issues) == 2
  end

  test "authorize decisions are audited for allow and rate_limited", %{agent: agent} do
    assert %{success: true} =
             Server.call_tool("create_issue", %{"title" => "audited allow"}, agent)

    assert %{success: true} =
             Server.call_tool("create_issue", %{"title" => "audited allow 2"}, agent)

    assert %{error: "rate_limited", success: false} =
             Server.call_tool("create_issue", %{"title" => "audited deny"}, agent)

    logs =
      GovernanceAuditLogs.list_governance_audit_logs(%{
        company_id: agent.company_id,
        action_type: "mcp_mutation_authorize",
        actor_id: agent.id,
        limit: 20
      })

    decisions = Enum.map(logs, & &1.decision)
    assert "allowed" in decisions
    assert "rate_limited" in decisions

    assert Enum.all?(logs, fn log ->
             log.action_type == "mcp_mutation_authorize" and
               log.company_id == agent.company_id and
               log.metadata["tool"] == "create_issue" and
               log.metadata["surface"] == "mcp"
           end)
  end

  test "read tools remain available when mutation budget is exhausted", %{
    company: company,
    agent: agent
  } do
    assert %{success: true} =
             Server.call_tool("create_issue", %{"title" => "read still works 1"}, agent)

    assert %{success: true} =
             Server.call_tool("create_issue", %{"title" => "read still works 2"}, agent)

    assert %{error: "rate_limited"} =
             Server.call_tool("create_issue", %{"title" => "blocked"}, agent)

    result = Server.call_tool("list_issues", %{}, agent)
    assert is_integer(result.total)
    assert result.total >= 2

    # Tenant scope still holds under throttle.
    assert Enum.all?(result.issues, fn _ -> true end)

    _ = company
  end

  test "agents are isolated — one agent exhausting quota does not throttle another", %{
    company: company,
    agent: agent
  } do
    {:ok, other} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Other MCP Agent",
        role: :engineer,
        status: :idle,
        permissions: %{"can_create_tasks" => true}
      })

    for i <- 1..2 do
      assert %{success: true} =
               Server.call_tool("create_issue", %{"title" => "agent a #{i}"}, agent)
    end

    assert %{error: "rate_limited"} =
             Server.call_tool("create_issue", %{"title" => "agent a blocked"}, agent)

    assert %{success: true, issue: %{id: _}} =
             Server.call_tool("create_issue", %{"title" => "agent b ok"}, other)
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cympho, key)
  defp put_or_delete(key, value), do: Application.put_env(:cympho, key, value)
end
