defmodule Cympho.ToolCallTraces do
  @moduledoc """
  The ToolCallTraces context manages immutable tool-call tracing with hash chain integrity.
  """

  import Ecto.Query
  alias Cympho.{Repo, ToolCallTraces.ToolCallTrace}

  def list_tool_call_traces(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    issue_id = Keyword.get(opts, :issue_id)
    agent_id = Keyword.get(opts, :agent_id)
    actor_type = Keyword.get(opts, :actor_type)
    actor_id = Keyword.get(opts, :actor_id)
    tool_name = Keyword.get(opts, :tool_name)
    status = Keyword.get(opts, :status)

    ToolCallTrace
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_issue(issue_id)
    |> maybe_filter_by_agent(agent_id)
    |> maybe_filter_by_actor_type(actor_type)
    |> maybe_filter_by_actor_id(actor_id)
    |> maybe_filter_by_tool_name(tool_name)
    |> maybe_filter_by_status(status)
    |> order_by([t], desc: t.occurred_at)
    |> Repo.all()
  end

  def get_tool_call_trace(id) do
    case Repo.get(ToolCallTrace, id) do
      nil -> {:error, :not_found}
      trace -> {:ok, Repo.preload(trace, [:agent, :issue, :company])}
    end
  end

  def get_tool_call_trace_by_content_hash(content_hash) do
    query = from t in ToolCallTrace, where: t.content_hash == ^content_hash

    case Repo.one(query) do
      nil -> {:error, :not_found}
      trace -> {:ok, trace}
    end
  end

  def get_latest_trace(company_id) do
    query =
      from t in ToolCallTrace,
      where: t.company_id == ^company_id,
      order_by: [desc: t.sequence_number],
      limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      trace -> {:ok, trace}
    end
  end

  def create_tool_call_trace(attrs \\ %{}) do
    company_id = Map.get(attrs, :company_id) || Map.get(attrs, "company_id")

    if !company_id do
      {:error, :company_id_required}
    else
      case get_next_sequence_number(company_id) do
        {:error, reason} -> {:error, reason}
        {:ok, sequence_number} ->
          attrs = Map.put(attrs, :sequence_number, sequence_number)

          prev_chain_hash = case get_latest_trace(company_id) do
            {:ok, latest} -> latest.chain_hash
            {:error, :not_found} -> nil
          end

          changeset = ToolCallTrace.creation_changeset(attrs, prev_chain_hash)

          case Repo.insert(changeset) do
            {:ok, trace} -> {:ok, Repo.preload(trace, [:agent, :issue, :company])}
            error -> error
          end
      end
    end
  end

  def update_tool_call_trace_status(%ToolCallTrace{} = trace, status, result \\ nil) do
    attrs = %{status: status}

    attrs = if result do
      Map.put(attrs, :tool_result, result)
    else
      attrs
    end

    trace
    |> ToolCallTrace.changeset(attrs)
    |> Repo.update()
  end

  def verify_chain_integrity(company_id) do
    traces =
      ToolCallTrace
      |> where([t], t.company_id == ^company_id)
      |> order_by([t], asc: t.sequence_number)
      |> Repo.all()

    verify_chain(traces)
  end

  def verify_chain([_]), do: :ok
  def verify_chain([]), do: :ok
  def verify_chain([current | rest]) do
    case Enum.at(rest, 0) do
      nil -> :ok
      next_trace ->
        if next_trace.prev_hash == current.chain_hash do
          verify_chain(rest)
        else
          {:error, :chain_broken, current.sequence_number, next_trace.sequence_number}
        end
    end
  end

  def verify_content_hash(%ToolCallTrace{} = trace) do
    {expected_hash, _} = ToolCallTrace.calculate_content_hash(%{
      trace_type: trace.trace_type,
      tool_name: trace.tool_name,
      tool_arguments: trace.tool_arguments,
      tool_result: trace.tool_result,
      error_message: trace.error_message,
      status: trace.status,
      occurred_at: trace.occurred_at,
      actor_type: trace.actor_type,
      actor_id: trace.actor_id
    })

    if expected_hash == trace.content_hash do
      :ok
    else
      {:error, :content_hash_mismatch}
    end
  end

  def get_chain_traces(company_id, start_sequence \\ nil, limit \\ 100) do
    query =
      ToolCallTrace
      |> where([t], t.company_id == ^company_id)

    query = if start_sequence do
      where(query, [t], t.sequence_number >= ^start_sequence)
    else
      query
    end

    query
    |> order_by([t], asc: t.sequence_number)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_statistics(company_id, opts \\ []) do
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)

    base_query =
      ToolCallTrace
      |> where([t], t.company_id == ^company_id)

    query = if start_date do
      where(base_query, [t], t.occurred_at >= ^start_date)
    else
      base_query
    end

    query = if end_date do
      where(query, [t], t.occurred_at <= ^end_date)
    else
      query
    end

    total_calls = Repo.aggregate(query, :count, :id)

    success_calls =
      query
      |> where([t], t.status == "success")
      |> Repo.aggregate(:count, :id)

    error_calls =
      query
      |> where([t], t.status == "error")
      |> Repo.aggregate(:count, :id)

    %{
      total_calls: total_calls,
      success_calls: success_calls,
      error_calls: error_calls,
      pending_calls: total_calls - success_calls - error_calls
    }
  end

  defp get_next_sequence_number(company_id) do
    query =
      from t in ToolCallTrace,
      where: t.company_id == ^company_id,
      select: max(t.sequence_number)

    case Repo.one(query) do
      nil -> {:ok, 1}
      max_seq when is_integer(max_seq) -> {:ok, max_seq + 1}
    end
  end

  defp maybe_filter_by_company(query, nil), do: query
  defp maybe_filter_by_company(query, company_id) do
    from t in query, where: t.company_id == ^company_id
  end

  defp maybe_filter_by_issue(query, nil), do: query
  defp maybe_filter_by_issue(query, issue_id) do
    from t in query, where: t.issue_id == ^issue_id
  end

  defp maybe_filter_by_agent(query, nil), do: query
  defp maybe_filter_by_agent(query, agent_id) do
    from t in query, where: t.agent_id == ^agent_id
  end

  defp maybe_filter_by_actor_type(query, nil), do: query
  defp maybe_filter_by_actor_type(query, actor_type) do
    from t in query, where: t.actor_type == ^actor_type
  end

  defp maybe_filter_by_actor_id(query, nil), do: query
  defp maybe_filter_by_actor_id(query, actor_id) do
    from t in query, where: t.actor_id == ^actor_id
  end

  defp maybe_filter_by_tool_name(query, nil), do: query
  defp maybe_filter_by_tool_name(query, tool_name) do
    from t in query, where: t.tool_name == ^tool_name
  end

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, status) do
    from t in query, where: t.status == ^status
  end
end
