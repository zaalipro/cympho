defmodule Cympho.Recovery do
  @moduledoc "Durable case and lease lifecycle for stranded work recovery."
  import Ecto.Query
  alias Cympho.Repo
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.HeartbeatEngine
  alias Cympho.Workspaces
  alias Cympho.Orchestrator
  alias Cympho.RuntimeOperations
  alias Cympho.Recovery.{Fingerprint, RecoveryAttempt, RecoveryCase}

  @lease_seconds 300
  @backoff_seconds %{1 => 60, 2 => 120}

  @spec ensure_case(map()) :: {:ok, RecoveryCase.t()} | {:error, term()}
  def ensure_case(attrs) when is_map(attrs) do
    source_type = attrs[:source_type] || attrs["source_type"]
    issue_input = attrs[:issue] || attrs["issue"]
    run = attrs[:run] || attrs[:source_run] || attrs["run"] || attrs["source_run"]

    with {:ok, issue} <- load_issue(issue_input),
         :ok <- validate_input_scope(issue_input, issue),
         :ok <- validate_scope(issue, attrs, run),
         {:ok, fingerprint, snapshot, source_id, source_status, agent_id, source_run_id} <-
           source_details(source_type, issue, run) do
      do_ensure_case(%{
        company_id: issue.company_id,
        issue_id: issue.id,
        agent_id: agent_id,
        source_run_id: source_run_id,
        source_type: source_type,
        source_id: source_id,
        source_status: source_status,
        source_fingerprint: fingerprint,
        source_snapshot: snapshot,
        max_attempts: attrs[:max_attempts] || attrs["max_attempts"] || 3
      })
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "recovery_cases_active_source_index" do
        attrs
        |> reload_active_case()
        |> case do
          {:ok, row} -> {:ok, row}
          _ -> {:error, e}
        end
      else
        {:error, e}
      end
  end

  @spec claim_case(RecoveryCase.t() | binary(), keyword()) ::
          {:ok, %{case: RecoveryCase.t(), attempt: RecoveryAttempt.t(), token: String.t()}}
          | {:error, atom()}
  def claim_case(%RecoveryCase{id: id}, opts), do: claim_case(id, opts)

  def claim_case(id, opts) when is_binary(id) do
    now = option_now(opts)
    lease_seconds = Keyword.get(opts, :lease_seconds, @lease_seconds)
    claimed_by = Keyword.get(opts, :claimed_by, node() |> to_string())

    Repo.transaction(fn ->
      case Repo.one(from c in RecoveryCase, where: c.id == ^id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        case_row ->
          cond do
            case_row.state == "claimed" and expired?(case_row.lease_expires_at, now) == false ->
              Repo.rollback(:already_claimed)

            case_row.state not in ["detected", "scheduled", "claimed"] ->
              Repo.rollback(:not_claimable)

            (case_row.state == "scheduled" and case_row.next_attempt_at) &&
                DateTime.compare(case_row.next_attempt_at, now) == :gt ->
              Repo.rollback(:not_due)

            true ->
              attempt_no = case_row.attempt_count + 1

              if attempt_no > case_row.max_attempts do
                Repo.rollback(:exhausted)
              end

              token = Ecto.UUID.generate()
              claimed_at = now
              expires = DateTime.add(now, lease_seconds, :second)

              {1, _} =
                Repo.update_all(
                  from(c in RecoveryCase, where: c.id == ^id),
                  set: [
                    state: "claimed",
                    attempt_count: attempt_no,
                    claim_token: token,
                    claimed_at: claimed_at,
                    lease_expires_at: expires,
                    claimed_by: claimed_by,
                    last_attempt_at: now
                  ]
                )

              attempt =
                %RecoveryAttempt{}
                |> RecoveryAttempt.changeset(%{
                  recovery_case_id: id,
                  attempt_no: attempt_no,
                  status: "claimed",
                  action: "retry",
                  source_fingerprint: case_row.source_fingerprint,
                  started_at: now,
                  node: claimed_by
                })
                |> Repo.insert!()

              updated = Repo.get!(RecoveryCase, id)
              %{case: updated, attempt: attempt, token: token}
          end
      end
    end)
  end

  @spec record_success(map(), term()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_success(lease, opts_or_result \\ %{}) do
    now = option_now(opts_or_result)
    complete_attempt(lease, "succeeded", nil, "recovered", now)
  end

  @spec record_superseded(map(), term()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_superseded(lease, opts_or_result \\ %{}) do
    now = option_now(opts_or_result)
    complete_attempt(lease, "skipped", nil, "superseded", now)
  end

  @spec record_failure(map(), term(), keyword()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_failure(lease, reason, opts \\ []) do
    now = option_now(opts)

    with {:ok, id, token, attempt} <- lease_parts(lease) do
      Repo.transaction(fn ->
        case Repo.one(
               from c in RecoveryCase,
                 where:
                   c.id == ^id and c.claim_token == ^token and c.state == "claimed" and
                     (is_nil(c.lease_expires_at) or c.lease_expires_at > ^now),
                 lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.rollback(:stale_claim)

          case_row ->
            attempt_no = attempt.attempt_no
            exhausted = attempt_no >= case_row.max_attempts

            {state, next_retry_at} =
              if exhausted,
                do: {"exhausted", nil},
                else: {"scheduled", DateTime.add(now, retry_delay(attempt_no, opts), :second)}

            error = bounded_error(reason)

            {attempt_count, _} =
              Repo.update_all(
                from(a in RecoveryAttempt,
                  where:
                    a.id == ^attempt.id and a.recovery_case_id == ^id and
                      a.attempt_no == ^attempt.attempt_no and a.status == "claimed"
                ),
                set: [
                  status: "failed",
                  completed_at: now,
                  error_reason: error,
                  next_retry_at: next_retry_at
                ]
              )

            if attempt_count == 0, do: Repo.rollback(:stale_claim)

            updates = [
              state: state,
              claim_token: nil,
              claimed_at: nil,
              lease_expires_at: nil,
              claimed_by: nil,
              last_error: error,
              next_attempt_at: next_retry_at
            ]

            updates = if exhausted, do: [{:exhausted_at, now} | updates], else: updates

            Repo.update_all(
              from(c in RecoveryCase, where: c.id == ^id and c.claim_token == ^token),
              set: updates
            )

            Repo.get!(RecoveryCase, id)
        end
      end)
    end
  end

  @spec with_attempt(map() | RecoveryCase.t(), keyword(), (map() -> term())) ::
          {:ok, map()} | {:error, term()}
  def with_attempt(source, opts, callback) when is_function(callback, 1) do
    with {:ok, case_row} <- ensure_source(source),
         {:ok, lease} <- claim_case(case_row, opts) do
      result =
        try do
          callback.(lease)
        rescue
          exception -> {:error, {:exception, exception}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      outcome_result =
        case result do
          {:ok, value} ->
            {:ok, record_success(lease, opts), value, :recovered}

          {:error, :superseded} ->
            {:ok, record_superseded(lease, opts), result, :superseded}

          {:error, reason} ->
            {:ok, record_failure(lease, reason, opts), result, outcome_for_failure(lease)}

          value ->
            {:ok, record_success(lease, opts), value, :recovered}
        end

      case outcome_result do
        {:ok, {:ok, updated}, value, outcome} ->
          {:ok, %{result: value, outcome: outcome, case: updated}}

        {:ok, {:error, reason}, _value, _outcome} ->
          {:error, reason}
      end
    end
  end

  @doc "Routes stale heartbeat-run recovery through a durable case and lease."
  @spec recover_stale_run(Run.t(), keyword()) ::
          {:ok, %{run: Run.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_stale_run(%Run{} = run, opts \\ []) do
    recover_run(run, :stale, opts)
  end

  @doc "Routes orphaned heartbeat-run recovery through a durable case and lease."
  @spec recover_orphaned_run(Run.t(), keyword()) ::
          {:ok, %{run: Run.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_orphaned_run(%Run{} = run, opts \\ []) do
    recover_run(run, :orphaned, opts)
  end

  @doc "Routes stale checkout recovery through durable cases and leases."
  @spec recover_orphaned_issue(Issue.t(), keyword()) ::
          {:ok, %{issue: Issue.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_orphaned_issue(issue, opts \\ [])

  def recover_orphaned_issue(%Issue{} = issue, opts) do
    recovery_opts = Keyword.get(opts, :recovery_opts, opts)

    source =
      %{source_type: "issue_checkout", issue: issue}
      |> maybe_put_option(:max_attempts, opts)

    with {:ok, result} <-
           with_attempt(
             source,
             recovery_opts,
             fn _lease ->
               recover_checkout(issue)
             end
           ) do
      {:ok,
       %{
         issue: checkout_result_issue(result.result, issue),
         outcome: result.outcome,
         case: result.case
       }}
    end
  end

  def recover_orphaned_issue(_issue, _opts), do: {:error, :issue_required}

  @doc "Recovers all stale checked-out issues and returns stable aggregate counts."
  @spec recover_stale_checkouts(keyword()) :: %{
          checked: non_neg_integer(),
          released: non_neg_integer(),
          failed: non_neg_integer(),
          exhausted: non_neg_integer()
        }
  def recover_stale_checkouts(opts \\ []) do
    {result, _telemetry} = recover_stale_checkouts_with_telemetry(opts)
    result
  end

  @doc false
  def recover_stale_checkouts_with_telemetry(opts \\ []) do
    issues = RuntimeOperations.stale_checked_out_issues_all(opts)
    existing_sources = recovery_source_keys("issue_checkout")

    {result, telemetry, _seen_sources} =
      Enum.reduce(
        issues,
        {%{checked: 0, released: 0, failed: 0, exhausted: 0}, %{cases_created: 0, attempts: 0},
         existing_sources},
        fn issue, {acc, telemetry, seen_sources} ->
          acc = %{acc | checked: acc.checked + 1}

          case recover_orphaned_issue(issue, opts) do
            {:ok, %{outcome: :recovered, case: recovery_case}} ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {%{acc | released: acc.released + 1}, telemetry, seen_sources}

            {:ok, %{outcome: :exhausted, case: recovery_case}} ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {%{acc | exhausted: acc.exhausted + 1}, telemetry, seen_sources}

            {:ok, %{outcome: outcome, case: recovery_case}}
            when outcome in [:superseded, :scheduled] ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {if(outcome == :scheduled, do: %{acc | failed: acc.failed + 1}, else: acc),
               telemetry, seen_sources}

            {:error, _reason} ->
              {%{acc | failed: acc.failed + 1}, telemetry, seen_sources}
          end
        end
      )

    {result, telemetry}
  rescue
    _error ->
      {%{checked: 0, released: 0, failed: 0, exhausted: 0}, %{cases_created: 0, attempts: 0}}
  end

  defp recovery_source_keys(source_type) do
    Repo.all(
      from c in RecoveryCase,
        where: c.source_type == ^source_type and c.state in ^RecoveryCase.active_states(),
        select: {c.source_type, c.source_id}
    )
    |> MapSet.new()
  end

  defp update_recovery_telemetry(telemetry, seen_sources, nil), do: {telemetry, seen_sources}

  defp update_recovery_telemetry(telemetry, seen_sources, %{source_type: type, source_id: id}) do
    source = {type, id}
    telemetry = %{telemetry | attempts: telemetry.attempts + 1}

    if MapSet.member?(seen_sources, source) do
      {telemetry, seen_sources}
    else
      {%{telemetry | cases_created: telemetry.cases_created + 1},
       MapSet.put(seen_sources, source)}
    end
  end

  defp recover_run(%Run{} = run, kind, opts) do
    source =
      %{source_type: "heartbeat_run", issue: nil, run: run}
      |> maybe_put_option(:max_attempts, opts)

    with {:ok, issue} <- Issues.get_issue(run.issue_id),
         {:ok, result} <-
           with_attempt(
             %{source | issue: issue},
             Keyword.get(opts, :recovery_opts, opts),
             fn _lease ->
               callback =
                 if kind == :stale,
                   do: &HeartbeatEngine.recover_stale_run/1,
                   else: &HeartbeatEngine.recover_orphaned_run/1

               case callback.(run) do
                 {:error, {:invalid_status, _status}} -> {:error, :superseded}
                 {:ok, updated} -> {:ok, updated}
                 {:error, reason} -> {:error, reason}
               end
             end
           ) do
      {:ok,
       %{
         run: run_result(result.result, run),
         outcome: result.outcome,
         case: result.case
       }}
    end
  end

  defp maybe_put_option(source, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(source, key, value)
      :error -> source
    end
  end

  defp run_result(%Run{} = run, _fallback), do: run
  defp run_result(_, fallback), do: fallback

  defp checkout_result_issue(%Issue{} = issue, _fallback), do: issue
  defp checkout_result_issue(_, fallback), do: fallback

  defp recover_checkout(%Issue{} = issue) do
    cond do
      issue.status not in [:in_progress, "in_progress"] ->
        {:error, :superseded}

      live_runtime?(issue.id) ->
        {:error, :superseded}

      active_checkout_run?(issue.id) ->
        {:error, :superseded}

      true ->
        with {:ok, current} <- checkout_snapshot(issue),
             :ok <- ensure_no_active_checkout_run(issue.id),
             :ok <- ensure_no_live_runtime(issue.id) do
          release_result =
            Workspaces.cancel_and_release_for_issue(current, %{
              reason: "orphan_issue_reclaim",
              company_id: current.company_id
            })

          case release_result do
            {:error, reason} ->
              {:error, reason}

            :ok ->
              with :ok <- ensure_no_active_checkout_run(issue.id),
                   {:ok, current_after} <- checkout_snapshot(issue),
                   :ok <- ensure_no_live_runtime(issue.id) do
                case Issues.clear_checkout_lock(current_after, :todo) do
                  {:ok, cleared} -> {:ok, cleared}
                  {:error, _reason} -> {:error, :superseded}
                end
              else
                _ -> {:error, :superseded}
              end
          end
        else
          _ -> {:error, :superseded}
        end
    end
  end

  defp checkout_snapshot(%Issue{} = issue) do
    case Issues.get_issue(issue.id) do
      {:ok, current} ->
        if current.status in [:in_progress, "in_progress"] and
             current.lock_version == issue.lock_version and
             current.checkout_run_id == issue.checkout_run_id and
             current.checked_out_at == issue.checked_out_at do
          {:ok, current}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp ensure_no_active_checkout_run(issue_id),
    do: if(active_checkout_run?(issue_id), do: {:error, :active_run}, else: :ok)

  defp ensure_no_live_runtime(issue_id),
    do: if(live_runtime?(issue_id), do: {:error, :live_runtime}, else: :ok)

  defp active_checkout_run?(issue_id) do
    Repo.exists?(
      from r in Run,
        where: r.issue_id == ^issue_id and r.status in ["pending", "queued", "running"]
    )
  rescue
    _error -> true
  end

  defp live_runtime?(issue_id) do
    case Orchestrator.whereis(issue_id) do
      nil ->
        case Cympho.AdapterSessions.owners_for_issue(issue_id) do
          {:ok, []} -> false
          {:ok, [_ | _]} -> true
          {:error, :not_started} -> true
        end

      pid ->
        Process.alive?(pid) or live_adapter_worker?(issue_id)
    end
  end

  defp live_adapter_worker?(issue_id) do
    case Cympho.AdapterSessions.owners_for_issue(issue_id) do
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:error, :not_started} -> true
    end
  end

  defp ensure_source(%RecoveryCase{} = row), do: {:ok, row}
  defp ensure_source(source), do: ensure_case(source)

  defp complete_attempt(lease, status, error, state, now) do
    with {:ok, id, token, attempt} <- lease_parts(lease) do
      Repo.transaction(fn ->
        case Repo.one(
               from c in RecoveryCase,
                 where:
                   c.id == ^id and c.claim_token == ^token and c.state == "claimed" and
                     (is_nil(c.lease_expires_at) or c.lease_expires_at > ^now),
                 lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.rollback(:stale_claim)

          _case_row ->
            {attempt_count, _} =
              Repo.update_all(
                from(a in RecoveryAttempt,
                  where:
                    a.id == ^attempt.id and a.recovery_case_id == ^id and
                      a.attempt_no == ^attempt.attempt_no and a.status == "claimed"
                ),
                set: [status: status, completed_at: now, error_reason: error]
              )

            if attempt_count != 1, do: Repo.rollback(:stale_claim)

            updates = [
              state: state,
              claim_token: nil,
              claimed_at: nil,
              lease_expires_at: nil,
              claimed_by: nil,
              next_attempt_at: nil
            ]

            updates = if state == "recovered", do: [{:recovered_at, now} | updates], else: updates

            Repo.update_all(
              from(c in RecoveryCase, where: c.id == ^id and c.claim_token == ^token),
              set: updates
            )

            Repo.get!(RecoveryCase, id)
        end
      end)
    end
  end

  defp lease_parts(%{
         case: %RecoveryCase{id: id},
         token: token,
         attempt: %RecoveryAttempt{} = attempt
       }),
       do: {:ok, id, token, attempt}

  defp lease_parts(_), do: {:error, :invalid_lease}

  defp outcome_for_failure(%{
         case: %RecoveryCase{max_attempts: max},
         attempt: %RecoveryAttempt{attempt_no: no}
       })
       when no >= max, do: :exhausted

  defp outcome_for_failure(_), do: :scheduled

  defp load_issue(%Issue{id: id}) when is_binary(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :issue_not_found}
      issue -> {:ok, issue}
    end
  end

  defp load_issue(%{id: id}) when is_binary(id),
    do: if(issue = Repo.get(Issue, id), do: {:ok, issue}, else: {:error, :issue_not_found})

  defp load_issue(%{"id" => id}) when is_binary(id),
    do: if(issue = Repo.get(Issue, id), do: {:ok, issue}, else: {:error, :issue_not_found})

  defp load_issue(_), do: {:error, :issue_required}

  defp validate_input_scope(input, %Issue{company_id: company_id}) do
    case Map.get(input, :company_id) || Map.get(input, "company_id") do
      ^company_id when is_binary(company_id) and byte_size(company_id) > 0 -> :ok
      _ -> {:error, :company_scope_required}
    end
  end

  defp validate_scope(%Issue{company_id: company_id}, attrs, run)
       when is_binary(company_id) and byte_size(company_id) > 0 do
    requested = attrs[:company_id] || attrs["company_id"]

    cond do
      requested && requested != company_id ->
        {:error, :company_scope_required}

      run &&
          (run_field(run, :issue_id) != attrs_issue_id(attrs) ||
             run_field(run, :company_id) != company_id) ->
        {:error, :company_scope_required}

      true ->
        :ok
    end
  end

  defp validate_scope(_, _, _), do: {:error, :company_scope_required}

  defp attrs_issue_id(attrs) do
    issue = attrs[:issue] || attrs["issue"]
    field(issue, :id)
  end

  defp run_field(run, key), do: Map.get(run, key) || Map.get(run, Atom.to_string(key))

  defp source_details("issue_checkout", issue, _run) do
    {fingerprint, snapshot} = Fingerprint.for_issue_checkout(issue)

    {:ok, fingerprint, snapshot, field(issue, :id), to_string(field(issue, :status)),
     field(issue, :assignee_id), field(issue, :checkout_run_id)}
  end

  defp source_details("heartbeat_run", issue, run) when is_map(run) do
    run_id = field(run, :id)
    run_status = field(run, :status)
    issue_id = field(run, :issue_id)
    company_id = field(run, :company_id)

    cond do
      not is_binary(run_id) or run_id == "" ->
        {:error, :invalid_run_source}

      is_nil(run_status) or run_status == "" ->
        {:error, :invalid_run_source}

      issue_id != field(issue, :id) ->
        {:error, :company_scope_required}

      company_id != field(issue, :company_id) ->
        {:error, :company_scope_required}

      true ->
        {fingerprint, snapshot} = Fingerprint.for_run(run, issue)
        source_run_id = if match?(%Run{}, run), do: run_id, else: nil

        {:ok, fingerprint, snapshot, run_id, to_string(run_status), field(run, :agent_id),
         source_run_id}
    end
  end

  defp source_details("heartbeat_run", _issue, _), do: {:error, :run_required}
  defp source_details(_, _, _), do: {:error, :invalid_source_type}

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil

  defp do_ensure_case(attrs) do
    Repo.transaction(fn ->
      active =
        Repo.one(
          from c in RecoveryCase,
            where:
              c.company_id == ^attrs.company_id and c.source_type == ^attrs.source_type and
                c.source_id == ^attrs.source_id and c.state in ^RecoveryCase.active_states(),
            order_by: [desc: c.inserted_at],
            lock: "FOR UPDATE"
        )

      cond do
        active && active.source_fingerprint == attrs.source_fingerprint ->
          active

        active ->
          Repo.update_all(from(c in RecoveryCase, where: c.id == ^active.id),
            set: [state: "superseded"]
          )

          insert_case(attrs, active)

        true ->
          insert_case(attrs, nil)
      end
    end)
  end

  defp insert_case(attrs, parent) do
    root_id = if parent, do: parent.root_case_id || parent.id

    {:ok, row} =
      %RecoveryCase{}
      |> RecoveryCase.changeset(
        Map.merge(attrs, %{parent_case_id: parent && parent.id, root_case_id: root_id})
      )
      |> Repo.insert()

    if is_nil(root_id),
      do:
        Repo.update_all(from(c in RecoveryCase, where: c.id == ^row.id),
          set: [root_case_id: row.id]
        )

    Repo.get!(RecoveryCase, row.id)
  end

  defp reload_active_case(attrs) do
    source_type = attrs[:source_type] || attrs["source_type"]

    with {:ok, issue} <- load_issue(attrs[:issue] || attrs["issue"]) do
      run = attrs[:run] || attrs[:source_run] || attrs["run"] || attrs["source_run"]

      source_id =
        if source_type == "heartbeat_run",
          do: run_field(run, :id),
          else: issue.id

      case Repo.one(
             from c in RecoveryCase,
               where:
                 c.company_id == ^issue.company_id and c.source_type == ^source_type and
                   c.source_id == ^source_id and c.state in ^RecoveryCase.active_states()
           ) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  defp expired?(nil, _), do: true
  defp expired?(expires, now), do: DateTime.compare(expires, now) != :gt

  defp retry_delay(attempt_no, opts) do
    base = max(Keyword.get(opts, :base_delay, 60), 1)
    cap = max(Keyword.get(opts, :max_delay, 600), base)
    min(base * Integer.pow(2, max(attempt_no - 1, 0)), cap)
  end

  defp option_now(opts) when is_list(opts),
    do: Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

  defp option_now(%{now: now}), do: now
  defp option_now(_), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp bounded_error(nil), do: nil

  defp bounded_error(reason) do
    text = inspect(reason, limit: 20) |> String.downcase()

    cond do
      String.contains?(text, ["timeout", "timed out"]) -> "timeout"
      String.contains?(text, ["auth", "credential", "token", "secret"]) -> "authentication"
      String.contains?(text, ["rate", "429", "thrott"]) -> "rate_limited"
      String.contains?(text, ["network", "connect", "econn"]) -> "network"
      String.contains?(text, ["cancel"]) -> "cancelled"
      true -> "unknown"
    end
  end
end
