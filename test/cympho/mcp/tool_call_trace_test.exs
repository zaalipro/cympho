defmodule Cympho.Mcp.ToolCallTraceTest do
  @moduledoc """
  Tool-call traces are a governance surface: a hash-chained record of which
  agent invoked which tool, with a LiveView built on top that verifies chain
  integrity. Nothing in production ever wrote to it.

  Its only producer was `AgentRunner.extract_and_send_tool_calls/3`, which scans
  a Messages-API-shaped `content` array — and the stock `claude --output-format
  json` envelope this codebase builds and documents has no such key. No other
  adapter emitted the message at all, so the subsystem ran entirely on synthetic
  test messages. MCP is a real tool-call boundary and is now recorded.
  """

  use Cympho.DataCase, async: false

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Mcp.Server
  alias Cympho.ToolCallTraces

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Trace Co #{unique}",
        slug: "trace-co-#{unique}",
        issue_prefix: "TC"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        company_id: company.id,
        name: "Trace Agent",
        role: :engineer,
        status: :idle
      })

    %{company: company, agent: agent}
  end

  defp traces(company), do: ToolCallTraces.list_tool_call_traces(company_id: company.id)

  test "a successful tool call is recorded", %{company: company, agent: agent} do
    assert traces(company) == []

    assert %{} = Server.call_tool("list_issues", %{"status" => "todo"}, agent)

    assert [trace] = traces(company)
    assert trace.tool_name == "list_issues"
    assert trace.trace_type == "mcp_tool_call"
    assert trace.status == "success"
    assert trace.company_id == company.id
    assert trace.agent_id == agent.id
    assert trace.actor_type == "agent"
    assert is_nil(trace.error_message)
  end

  test "a failing tool call is recorded as an error", %{company: company, agent: agent} do
    assert %{error: _} = Server.call_tool("no_such_tool_at_all", %{}, agent)

    assert [trace] = traces(company)
    assert trace.tool_name == "no_such_tool_at_all"
    assert trace.status == "error"
    assert is_binary(trace.error_message)
  end

  test "traces are hash chained", %{company: company, agent: agent} do
    for _ <- 1..3, do: Server.call_tool("list_issues", %{}, agent)

    chained = traces(company) |> Enum.sort_by(& &1.sequence_number)
    assert length(chained) == 3

    for trace <- chained do
      assert String.match?(trace.chain_hash, ~r/^[a-f0-9]{64}$/)
      assert String.match?(trace.content_hash, ~r/^[a-f0-9]{64}$/)
    end

    # Each link names its predecessor, which is what the integrity view checks.
    [first, second, third] = chained
    assert is_nil(first.prev_hash) or first.prev_hash == ""
    assert second.prev_hash == first.chain_hash
    assert third.prev_hash == second.chain_hash
  end

  test "arguments are redacted before they are stored", %{company: company, agent: agent} do
    Server.call_tool("list_issues", %{"search" => "ok", "api_key" => "sk-live-not-this"}, agent)

    assert [trace] = traces(company)
    refute inspect(trace.tool_arguments) =~ "sk-live-not-this"
  end

  test "a trace failure never breaks the tool call", %{agent: agent} do
    # An agent with no company cannot produce a company-scoped trace; the call
    # itself must still answer.
    assert %{} = Server.call_tool("list_issues", %{}, %{agent | company_id: nil})
  end

  test "traces stay scoped to the calling agent's company", %{company: company, agent: agent} do
    unique = System.unique_integer([:positive])

    {:ok, other} =
      Companies.create_company(%{
        name: "Other Trace Co #{unique}",
        slug: "other-trace-co-#{unique}",
        issue_prefix: "OT"
      })

    Server.call_tool("list_issues", %{}, agent)

    assert length(traces(company)) == 1
    assert ToolCallTraces.list_tool_call_traces(company_id: other.id) == []
  end
end
