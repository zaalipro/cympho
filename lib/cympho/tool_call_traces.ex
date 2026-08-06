defmodule Cympho.ToolCallTraces do
  @moduledoc """
  The ToolCallTraces context manages immutable tool-call tracing with hash chain integrity.

  Write paths redact secret-like keys from tool arguments/results before hashing and
  persistence. Sequence assignment is serialized per company (transaction + lock) with
  retry on unique(company_id, sequence_number) conflicts.
  """

  import Ecto.Query
  alias Cympho.{Repo, ToolCallTraces.ToolCallTrace}

  @max_create_retries 8
  @redacted_placeholder "[REDACTED]"

  # Keys whose values must never be stored raw (aligned with company export scrubbing).
  @secret_fields MapSet.new(~w(
    password_hash
    key_hash
    encrypted_value
    webhook_secret
    github_webhook_secret
    api_key
    password
    secret
    token
    access_token
    refresh_token
    auth_token
    authorization
    cookie
    database_url
    key
    credential
    credentials
    headers
    env
    auth
    authentication
    secrets
    private_key
    client_secret
  ))

  @secret_field_suffixes ~w(
    _api_key
    _password
    _secret
    _token
    _authorization
    _cookie
    _database_url
    _key
    _credential
    _credentials
  )

  @secret_value_patterns [
    ~r/\bsk-[A-Za-z0-9_-]{8,}\b/i,
    ~r/\bbearer\s+[A-Za-z0-9._~+\/-]{12,}/i,
    ~r/\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    ~r/\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{20,}\b/i,
    ~r/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/i,
    ~r/\bAIza[A-Za-z0-9_-]{20,}\b/,
    ~r/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    ~r/-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----/i
  ]

  def list_tool_call_traces(opts \\ []) do
    company_id = Keyword.get(opts, :company_id)
    issue_id = Keyword.get(opts, :issue_id)
    agent_id = Keyword.get(opts, :agent_id)
    actor_type = Keyword.get(opts, :actor_type)
    actor_id = Keyword.get(opts, :actor_id)
    tool_name = Keyword.get(opts, :tool_name)
    status = Keyword.get(opts, :status)
    run_id = Keyword.get(opts, :run_id)

    ToolCallTrace
    |> maybe_filter_by_company(company_id)
    |> maybe_filter_by_issue(issue_id)
    |> maybe_filter_by_agent(agent_id)
    |> maybe_filter_by_actor_type(actor_type)
    |> maybe_filter_by_actor_id(actor_id)
    |> maybe_filter_by_tool_name(tool_name)
    |> maybe_filter_by_status(status)
    |> maybe_filter_by_run_id(run_id)
    |> order_by([t], desc: t.occurred_at)
    |> Repo.all()
  end

  @doc """
  Keyset (infinite-scroll) page of tool-call traces, newest first.

  Accepts the same filter options as `list_tool_call_traces/1` plus `:after`
  (a cursor) and `:limit`, and returns a `Cympho.Pagination.Page`. Keys on
  `(occurred_at, id)` so it stays correct across any filter combination,
  including the cross-company (unscoped) case.
  """
  def list_tool_call_traces_page(opts \\ []) do
    ToolCallTrace
    |> maybe_filter_by_company(Keyword.get(opts, :company_id))
    |> maybe_filter_by_issue(Keyword.get(opts, :issue_id))
    |> maybe_filter_by_agent(Keyword.get(opts, :agent_id))
    |> maybe_filter_by_actor_type(Keyword.get(opts, :actor_type))
    |> maybe_filter_by_actor_id(Keyword.get(opts, :actor_id))
    |> maybe_filter_by_tool_name(Keyword.get(opts, :tool_name))
    |> maybe_filter_by_status(Keyword.get(opts, :status))
    |> maybe_filter_by_run_id(Keyword.get(opts, :run_id))
    |> Cympho.Pagination.page(
      limit: Keyword.get(opts, :limit, 50),
      after: Keyword.get(opts, :after),
      cursor_fields: [{:occurred_at, :desc}, {:id, :desc}]
    )
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

  @doc """
  Creates a tool-call trace after redacting secret-like payload fields.

  Sequence numbers are assigned inside a transaction with a per-company advisory
  lock and row lock on the latest trace. Unique conflicts on
  `(company_id, sequence_number)` are retried.
  """
  def create_tool_call_trace(attrs \\ %{}) do
    company_id = Map.get(attrs, :company_id) || Map.get(attrs, "company_id")

    if !company_id do
      {:error, :company_id_required}
    else
      attrs = sanitize_write_attrs(attrs)
      create_with_retry(attrs, company_id, @max_create_retries)
    end
  end

  def update_tool_call_trace_status(%ToolCallTrace{} = trace, status, result \\ nil) do
    result = sanitize_tool_result(result)

    Repo.transaction(fn ->
      trace
      |> reload_chain_suffix_for_update()
      |> rehash_chain_suffix(status, result)
    end)
    |> case do
      {:ok, {:ok, updated}} ->
        updated = Repo.preload(updated, [:agent, :issue, :company])
        maybe_broadcast_trace(updated)
        {:ok, updated}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def verify_chain_integrity(company_id) do
    traces =
      ToolCallTrace
      |> where([t], t.company_id == ^company_id)
      |> order_by([t], asc: t.sequence_number)
      |> Repo.all()

    with :ok <- verify_trace_contents(traces) do
      verify_chain(traces)
    end
  end

  defp verify_trace_contents(traces) do
    Enum.reduce_while(traces, :ok, fn trace, :ok ->
      case verify_content_hash(trace) do
        :ok ->
          {:cont, :ok}

        {:error, :content_hash_mismatch} ->
          {:halt, {:error, :content_hash_mismatch, trace.sequence_number}}
      end
    end)
  end

  def verify_chain([_]), do: :ok
  def verify_chain([]), do: :ok

  def verify_chain([current | rest]) do
    case Enum.at(rest, 0) do
      nil ->
        :ok

      next_trace ->
        if next_trace.prev_hash == current.chain_hash do
          verify_chain(rest)
        else
          {:error, :chain_broken, current.sequence_number, next_trace.sequence_number}
        end
    end
  end

  def verify_content_hash(%ToolCallTrace{} = trace) do
    {expected_hash, _} =
      ToolCallTrace.calculate_content_hash(%{
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

    query =
      if start_sequence do
        where(query, [t], t.sequence_number >= ^start_sequence)
      else
        query
      end

    query
    |> order_by([t], asc: t.sequence_number)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_statistics(company_id, opts \\ [])

  def get_statistics(nil, _opts) do
    %{total_calls: 0, success_calls: 0, error_calls: 0, pending_calls: 0}
  end

  def get_statistics(company_id, opts) do
    start_date = Keyword.get(opts, :start_date)
    end_date = Keyword.get(opts, :end_date)

    base_query =
      ToolCallTrace
      |> where([t], t.company_id == ^company_id)

    query =
      if start_date do
        where(base_query, [t], t.occurred_at >= ^start_date)
      else
        base_query
      end

    query =
      if end_date do
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

  @doc """
  Redacts secret-like keys from tool argument maps (deep).

  Used by write paths and any re-emit surfaces (audit trail).
  """
  def redact_tool_arguments(args) when is_map(args), do: redact_value(args)
  def redact_tool_arguments(args) when is_list(args), do: Enum.map(args, &redact_value/1)
  def redact_tool_arguments(_), do: %{}

  @doc """
  Redacts or replaces tool results so secret material is not stored raw.

  When the body contains secret-like values it is replaced with a SHA-256
  digest of the original payload (`sha256:<hex>`). Benign results pass through
  after pattern scrubbing.
  """
  def redact_tool_result(result), do: sanitize_tool_result(result)

  # ── Write-path sanitization ──────────────────────────────────────────────

  defp sanitize_write_attrs(attrs) when is_map(attrs) do
    args = Map.get(attrs, :tool_arguments) || Map.get(attrs, "tool_arguments") || %{}
    result = Map.get(attrs, :tool_result) || Map.get(attrs, "tool_result")
    error = Map.get(attrs, :error_message) || Map.get(attrs, "error_message")

    attrs
    |> Map.put(:tool_arguments, redact_tool_arguments(args))
    |> Map.put(:tool_result, sanitize_tool_result(result))
    |> put_if_present(:error_message, sanitize_tool_result(error))
    |> Map.drop(["tool_arguments", "tool_result", "error_message"])
  end

  defp put_if_present(attrs, _key, nil), do: attrs
  defp put_if_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp sanitize_tool_result(nil), do: nil

  defp sanitize_tool_result(result) when is_binary(result) do
    case Jason.decode(result) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) ->
        redacted = redact_value(decoded)

        if redacted == decoded do
          scrub_secret_patterns(result)
        else
          "sha256:" <> sha256_hex(result)
        end

      _ ->
        scrubbed = scrub_secret_patterns(result)

        if scrubbed == result do
          result
        else
          "sha256:" <> sha256_hex(result)
        end
    end
  end

  defp sanitize_tool_result(result) when is_map(result) or is_list(result) do
    redacted = redact_value(result)

    if redacted == result do
      case Jason.encode(result) do
        {:ok, json} -> json
        _ -> inspect(result)
      end
    else
      "sha256:" <> sha256_hex(:erlang.term_to_binary(result))
    end
  end

  defp sanitize_tool_result(result), do: sanitize_tool_result(to_string(result))

  defp redact_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if secret_field?(key) do
        {key, @redacted_placeholder}
      else
        {key, redact_value(nested)}
      end
    end)
  end

  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)

  defp redact_value(value) when is_binary(value), do: scrub_secret_patterns(value)

  defp redact_value(value), do: value

  defp secret_field?(key) do
    normalized =
      key
      |> to_string()
      |> String.trim()
      |> String.downcase()

    MapSet.member?(@secret_fields, normalized) or
      Enum.any?(@secret_field_suffixes, &String.ends_with?(normalized, &1))
  end

  defp scrub_secret_patterns(text) when is_binary(text) do
    Enum.reduce(@secret_value_patterns, text, fn pattern, acc ->
      Regex.replace(pattern, acc, @redacted_placeholder)
    end)
  end

  defp sha256_hex(data) when is_binary(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  # ── Transactional sequence assignment ────────────────────────────────────

  defp create_with_retry(attrs, company_id, retries_left) do
    case insert_trace_transaction(attrs, company_id) do
      {:ok, trace} ->
        trace = Repo.preload(trace, [:agent, :issue, :company])
        maybe_broadcast_trace(trace)
        {:ok, trace}

      {:error, :sequence_conflict} when retries_left > 0 ->
        create_with_retry(attrs, company_id, retries_left - 1)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp insert_trace_transaction(attrs, company_id) do
    Repo.transaction(fn ->
      lock_company_sequence!(company_id)
      {sequence_number, prev_chain_hash} = next_sequence_and_prev_hash(company_id)
      attrs = Map.put(attrs, :sequence_number, sequence_number)

      case ToolCallTrace.creation_changeset(attrs, prev_chain_hash) |> Repo.insert() do
        {:ok, trace} ->
          trace

        {:error, changeset} ->
          if sequence_conflict?(changeset) do
            Repo.rollback(:sequence_conflict)
          else
            Repo.rollback(changeset)
          end
      end
    end)
    |> case do
      {:ok, trace} -> {:ok, trace}
      {:error, :sequence_conflict} -> {:error, :sequence_conflict}
      {:error, other} -> {:error, other}
    end
  end

  defp lock_company_sequence!(company_id) do
    # Serialize first-row and concurrent inserts even when the company chain is empty.
    key = :erlang.phash2({:tool_call_trace_seq, company_id}, 2_147_483_647)
    Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
    :ok
  end

  defp next_sequence_and_prev_hash(company_id) do
    query =
      from t in ToolCallTrace,
        where: t.company_id == ^company_id,
        order_by: [desc: t.sequence_number],
        limit: 1,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {1, nil}
      latest -> {latest.sequence_number + 1, latest.chain_hash}
    end
  end

  defp sequence_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:sequence_number, {_, opts}} ->
        Keyword.get(opts, :constraint) == :unique

      {:company_id, {_, opts}} ->
        Keyword.get(opts, :constraint_name) in sequence_constraint_names()

      _ ->
        false
    end) or
      Enum.any?(errors, fn
        {_, {_, opts}} ->
          Keyword.get(opts, :constraint_name) in sequence_constraint_names()

        _ ->
          false
      end)
  end

  defp sequence_conflict?(_), do: false

  defp sequence_constraint_names do
    [
      "tool_call_traces_company_id_sequence_number_index",
      :tool_call_traces_company_id_sequence_number_index
    ]
  end

  defp reload_chain_suffix_for_update(%ToolCallTrace{} = trace) do
    query =
      from t in ToolCallTrace,
        where: t.company_id == ^trace.company_id and t.sequence_number >= ^trace.sequence_number,
        order_by: [asc: t.sequence_number],
        lock: "FOR UPDATE"

    case Repo.all(query) do
      [] -> {:error, :not_found}
      traces -> {:ok, traces}
    end
  end

  defp rehash_chain_suffix({:error, reason}, _status, _result), do: {:error, reason}

  defp rehash_chain_suffix({:ok, [target | rest]}, status, result) do
    target_attrs =
      target
      |> trace_hash_attrs(status_update_attrs(status, result))
      |> Map.put(:prev_hash, target.prev_hash)
      |> put_hashes()

    with {:ok, updated_target} <- target |> ToolCallTrace.changeset(target_attrs) |> Repo.update(),
         {:ok, _last_hash} <- rehash_following_traces(rest, updated_target.chain_hash) do
      {:ok, updated_target}
    end
  end

  defp rehash_following_traces([], last_hash), do: {:ok, last_hash}

  defp rehash_following_traces([trace | rest], prev_hash) do
    attrs =
      trace
      |> trace_hash_attrs(%{})
      |> Map.put(:prev_hash, prev_hash)
      |> put_hashes()

    with {:ok, updated} <- trace |> ToolCallTrace.changeset(attrs) |> Repo.update() do
      rehash_following_traces(rest, updated.chain_hash)
    end
  end

  defp status_update_attrs(status, nil), do: %{status: status}
  defp status_update_attrs(status, result), do: %{status: status, tool_result: result}

  defp trace_hash_attrs(%ToolCallTrace{} = trace, overrides) do
    %{
      trace_type: trace.trace_type,
      tool_name: trace.tool_name,
      tool_arguments: trace.tool_arguments,
      tool_result: trace.tool_result,
      error_message: trace.error_message,
      status: trace.status,
      occurred_at: trace.occurred_at,
      actor_type: trace.actor_type,
      actor_id: trace.actor_id
    }
    |> Map.merge(overrides)
  end

  defp put_hashes(attrs) do
    {content_hash, _} = ToolCallTrace.calculate_content_hash(attrs)

    attrs
    |> Map.put(:content_hash, content_hash)
    |> Map.put(:chain_hash, ToolCallTrace.calculate_chain_hash(content_hash, attrs[:prev_hash]))
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

  defp maybe_filter_by_run_id(query, nil), do: query
  defp maybe_filter_by_run_id(query, ""), do: query

  defp maybe_filter_by_run_id(query, run_id) do
    from t in query, where: t.run_id == ^run_id
  end

  defp maybe_broadcast_trace(trace) do
    # Fail-closed: require a real company_id (never company::issues).
    if is_binary(trace.issue_id) and trace.issue_id != "" do
      Cympho.PubSubGuard.company_broadcast(
        trace.company_id,
        "issues",
        {:tool_call_trace_created, trace}
      )
    end
  end
end
