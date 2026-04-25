defmodule Cympho.ToolCallTracesTest do
  use Cympho.DataCase, async: false

  alias Cympho.ToolCallTraces
  alias Cympho.ToolCallTraces.ToolCallTrace
  alias Cympho.Companies

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company",
        slug: "test-company"
      })

    %{company: company}
  end

  describe "create_tool_call_trace/1" do
    test "creates trace with valid attrs and generates hash chain", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "test"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, %ToolCallTrace{} = trace} = ToolCallTraces.create_tool_call_trace(attrs)
      assert trace.trace_type == "llm_tool_call"
      assert trace.tool_name == "web_search"
      assert trace.status == "pending"
      assert trace.sequence_number == 1
      assert trace.content_hash =~ ~r/^[a-f0-9]{64}$/
      assert trace.chain_hash =~ ~r/^[a-f0-9]{64}$/
      assert is_nil(trace.prev_hash)
    end

    test "links to previous trace in chain", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "success",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "code_analysis",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace1} = ToolCallTraces.create_tool_call_trace(attrs1)
      assert {:ok, trace2} = ToolCallTraces.create_tool_call_trace(attrs2)

      assert trace2.sequence_number == 2
      assert trace2.prev_hash == trace1.chain_hash
      assert trace2.chain_hash != trace1.chain_hash
    end

    test "returns error without company_id" do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending"
      }

      assert {:error, :company_id_required} = ToolCallTraces.create_tool_call_trace(attrs)
    end

    test "prevents duplicate content_hash", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "same"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, _trace1} = ToolCallTraces.create_tool_call_trace(attrs)
      assert {:error, _changeset} = ToolCallTraces.create_tool_call_trace(attrs)
    end

    test "generates unique content_hash for different content", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "first"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "second"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace1} = ToolCallTraces.create_tool_call_trace(attrs1)
      assert {:ok, trace2} = ToolCallTraces.create_tool_call_trace(attrs2)

      assert trace1.content_hash != trace2.content_hash
    end
  end

  describe "hash chain calculation" do
    test "content_hash is deterministic", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "test"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace1} = ToolCallTraces.create_tool_call_trace(attrs)

      same_time = trace1.occurred_at

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "test"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: trace1.actor_id,
        occurred_at: same_time
      }

      assert {:ok, trace2} = ToolCallTraces.create_tool_call_trace(Map.put(attrs2, :company_id, company.id))

      assert trace1.content_hash != trace2.content_hash
    end

    test "chain_hash depends on both content_hash and prev_hash", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{"query" => "test"},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "code_analysis",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace1} = ToolCallTraces.create_tool_call_trace(attrs1)
      assert {:ok, trace2} = ToolCallTraces.create_tool_call_trace(attrs2)

      assert trace2.chain_hash != trace1.chain_hash
      assert trace2.prev_hash == trace1.chain_hash
    end
  end

  describe "verify_chain_integrity/1" do
    test "returns :ok for valid chain", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      for _ <- 1..5 do
        ToolCallTraces.create_tool_call_trace(attrs)
      end

      assert :ok = ToolCallTraces.verify_chain_integrity(company.id)
    end

    test "detects broken chain links", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace1} = ToolCallTraces.create_tool_call_trace(attrs)
      assert {:ok, trace2} = ToolCallTraces.create_tool_call_trace(attrs)

      from(t in ToolCallTrace, where: t.id == ^trace2.id)
      |> Repo.update_all(set: [prev_hash: "invalidhash00000000000000000000000000000000000000000000000000000000000"])

      assert {:error, :chain_broken, 1, 2} =
        ToolCallTraces.verify_chain_integrity(company.id)
    end

    test "returns :ok for empty chain", %{company: company} do
      assert :ok = ToolCallTraces.verify_chain_integrity(company.id)
    end
  end

  describe "verify_content_hash/1" do
    test "returns :ok for unmodified trace", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace} = ToolCallTraces.create_tool_call_trace(attrs)
      assert :ok = ToolCallTraces.verify_content_hash(trace)
    end

    test "returns error for modified trace", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace} = ToolCallTraces.create_tool_call_trace(attrs)

      from(t in ToolCallTrace, where: t.id == ^trace.id)
      |> Repo.update_all(set: [tool_name: "modified_tool"])

      assert {:error, :content_hash_mismatch} =
        ToolCallTraces.verify_content_hash(trace)
    end
  end

  describe "list_tool_call_traces/1" do
    test "returns all traces for company", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      for _ <- 1..3 do
        ToolCallTraces.create_tool_call_trace(attrs)
      end

      traces = ToolCallTraces.list_tool_call_traces(company_id: company.id)
      assert length(traces) == 3
    end

    test "filters by tool_name", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "code_analysis",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      ToolCallTraces.create_tool_call_trace(attrs1)
      ToolCallTraces.create_tool_call_trace(attrs2)

      traces =
        ToolCallTraces.list_tool_call_traces(
          company_id: company.id,
          tool_name: "web_search"
        )

      assert length(traces) == 1
      assert hd(traces).tool_name == "web_search"
    end

    test "filters by status", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "success",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "code_analysis",
        tool_arguments: %{},
        status: "error",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      ToolCallTraces.create_tool_call_trace(attrs1)
      ToolCallTraces.create_tool_call_trace(attrs2)

      traces =
        ToolCallTraces.list_tool_call_traces(
          company_id: company.id,
          status: "success"
        )

      assert length(traces) == 1
      assert hd(traces).status == "success"
    end
  end

  describe "get_statistics/2" do
    test "returns correct statistics", %{company: company} do
      attrs1 = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "success",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs2 = %{
        trace_type: "llm_tool_call",
        tool_name: "code_analysis",
        tool_arguments: %{},
        status: "error",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      attrs3 = %{
        trace_type: "llm_tool_call",
        tool_name: "file_read",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      ToolCallTraces.create_tool_call_trace(attrs1)
      ToolCallTraces.create_tool_call_trace(attrs2)
      ToolCallTraces.create_tool_call_trace(attrs3)

      stats = ToolCallTraces.get_statistics(company.id)

      assert stats.total_calls == 3
      assert stats.success_calls == 1
      assert stats.error_calls == 1
      assert stats.pending_calls == 1
    end
  end

  describe "update_tool_call_trace_status/3" do
    test "updates status and result", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      assert {:ok, trace} = ToolCallTraces.create_tool_call_trace(attrs)

      assert {:ok, updated} =
        ToolCallTraces.update_tool_call_trace_status(trace, "success", "result data")

      assert updated.status == "success"
      assert updated.tool_result == "result data"
    end
  end

  describe "get_chain_traces/3" do
    test "returns traces in sequence order", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      for _ <- 1..5 do
        ToolCallTraces.create_tool_call_trace(attrs)
      end

      traces = ToolCallTraces.get_chain_traces(company.id)

      assert length(traces) == 5
      assert Enum.map(traces, & &1.sequence_number) == Enum.sort(Enum.map(traces, & &1.sequence_number))
    end

    test "respects start_sequence parameter", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      for _ <- 1..5 do
        ToolCallTraces.create_tool_call_trace(attrs)
      end

      traces = ToolCallTraces.get_chain_traces(company.id, 3)

      assert length(traces) == 3
      assert hd(traces).sequence_number == 3
    end

    test "respects limit parameter", %{company: company} do
      attrs = %{
        trace_type: "llm_tool_call",
        tool_name: "web_search",
        tool_arguments: %{},
        status: "pending",
        company_id: company.id,
        actor_type: "agent",
        actor_id: Ecto.UUID.generate()
      }

      for _ <- 1..10 do
        ToolCallTraces.create_tool_call_trace(attrs)
      end

      traces = ToolCallTraces.get_chain_traces(company.id, nil, 5)

      assert length(traces) == 5
    end
  end
end
