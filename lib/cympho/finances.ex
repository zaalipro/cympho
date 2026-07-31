defmodule Cympho.Finances do
  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Cympho.{Agents, Companies, Issues, Wakes}
  alias Cympho.Repo

  alias Cympho.Finances.TokenUsage
  alias Cympho.Finances.BudgetPolicy
  alias Cympho.Finances.BudgetIncident
  alias Cympho.Finances.FinanceEvent
  alias Cympho.Finances.Biller
  alias Cympho.Finances.WorkProduct
  alias Cympho.HeartbeatEngine
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Companies.Company

  require Logger

  # Token Usage

  def list_token_usages(company_id, opts \\ []) do
    TokenUsage
    |> where(company_id: ^company_id)
    |> maybe_filter(:agent_id, opts[:agent_id])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:goal_id, opts[:goal_id])
    |> maybe_filter(:issue_id, opts[:issue_id])
    |> maybe_filter(:provider, opts[:provider])
    |> maybe_filter(:model, opts[:model])
    |> order_by(desc: :inserted_at)
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def get_token_usage!(id), do: Repo.get!(TokenUsage, id)

  def get_token_usage(id) do
    case Repo.get(TokenUsage, id) do
      nil -> {:error, :not_found}
      token_usage -> {:ok, token_usage}
    end
  end

  def record_token_usage(attrs) do
    with :ok <- validate_heartbeat_run_scope(attrs) do
      do_record_token_usage(attrs)
    end
  end

  defp do_record_token_usage(attrs) do
    Multi.new()
    |> Multi.insert(:token_usage, TokenUsage.changeset(%TokenUsage{}, attrs))
    |> Multi.insert(:finance_event, fn %{token_usage: tu} ->
      FinanceEvent.changeset(%FinanceEvent{}, %{
        company_id: tu.company_id,
        token_usage_id: tu.id,
        event_type: "token_usage",
        amount_usd: tu.cost_usd,
        description: "Token usage: #{tu.provider}/#{tu.model}"
      })
    end)
    |> Multi.run(:budget_evaluation, fn _repo, %{token_usage: token_usage} ->
      check_budget_thresholds(token_usage)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, result} ->
        enforce_hard_stops(result.budget_evaluation.blocked_policies)

        if result.budget_evaluation.blocked_policies == [] do
          {:ok, result.token_usage}
        else
          # The provider spend already happened. Keep the usage, finance
          # event, and incident committed, then reject future work.
          {:error, :budget_blocked}
        end

      {:error, :token_usage, %Ecto.Changeset{} = changeset, changes} ->
        case existing_heartbeat_run_usage(attrs, changeset) do
          %TokenUsage{} = token_usage ->
            {:ok, token_usage}

          nil ->
            {:error, :token_usage, changeset, changes}
        end

      {:error, failed_operation, failed_value, changes} ->
        {:error, failed_operation, failed_value, changes}
    end
  end

  def aggregate_usage(company_id, opts \\ []) do
    period = Keyword.get(opts, :period, "monthly")

    TokenUsage
    |> where(company_id: ^company_id)
    |> maybe_filter(:agent_id, opts[:agent_id])
    |> maybe_filter(:project_id, opts[:project_id])
    |> maybe_filter(:goal_id, opts[:goal_id])
    |> maybe_filter(:issue_id, opts[:issue_id])
    |> filter_by_period(period, opts[:from], opts[:to])
    |> select([t], %{
      total_tokens: sum(t.total_tokens),
      total_cost: sum(t.cost_usd),
      count: count(t.id)
    })
    |> Repo.one()
  end

  @doc """
  Checks active hard-stop policies before a runtime run is created.

  The returned shape is shared by both `Runtime.preflight/3` and the
  heartbeat run creator so callers cannot bypass a committed hard stop by
  skipping the higher-level preflight.
  """
  @spec check_runtime_budget(map(), map()) :: {:ok, map()} | {:error, {:budget_blocked, map()}}
  def check_runtime_budget(issue, agent) when is_map(issue) and is_map(agent) do
    company_id = Map.get(issue, :company_id) || Map.get(agent, :company_id)

    blocked_policy =
      company_id
      |> active_budget_policies()
      |> Enum.find(fn policy ->
        policy.action_on_exceed == "block" and
          policy_applies_to_runtime?(policy, issue, agent) and
          budget_exhausted?(policy)
      end)

    case blocked_policy do
      nil ->
        {:ok, %{status: "available"}}

      %BudgetPolicy{} = policy ->
        {:error,
         {:budget_blocked,
          %{
            policy_id: policy.id,
            scope: policy.scope,
            scope_id: policy.scope_id,
            period: policy.period,
            limit_usd: Decimal.to_string(policy.budget_limit_usd)
          }}}
    end
  end

  # Budget Policies

  def list_budget_policies(company_id, opts \\ []) do
    BudgetPolicy
    |> where(company_id: ^company_id)
    |> maybe_filter(:scope, opts[:scope])
    |> maybe_filter(:is_active, opts[:is_active])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_budget_policy!(id), do: Repo.get!(BudgetPolicy, id)

  def get_budget_policy(id) do
    case Repo.get(BudgetPolicy, id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def create_budget_policy(attrs) do
    %BudgetPolicy{}
    |> BudgetPolicy.changeset(attrs)
    |> Repo.insert()
  end

  def update_budget_policy(%BudgetPolicy{} = policy, attrs) do
    policy
    |> BudgetPolicy.changeset(attrs)
    |> Repo.update()
  end

  def delete_budget_policy(%BudgetPolicy{} = policy) do
    Repo.delete(policy)
  end

  # Budget Incidents

  def list_budget_incidents(company_id, opts \\ []) do
    BudgetIncident
    |> where(company_id: ^company_id)
    |> maybe_filter(:budget_policy_id, opts[:budget_policy_id])
    |> maybe_filter(:event_type, opts[:event_type])
    |> where([i], is_nil(i.resolved_at))
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_budget_incident!(id), do: Repo.get!(BudgetIncident, id)

  def resolve_budget_incident(%BudgetIncident{} = incident) do
    incident
    |> BudgetIncident.resolve_changeset(%{resolved_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # Finance Events

  def list_finance_events(company_id, opts \\ []) do
    FinanceEvent
    |> where(company_id: ^company_id)
    |> maybe_filter(:event_type, opts[:event_type])
    |> order_by(desc: :inserted_at)
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  def get_finance_event!(id), do: Repo.get!(FinanceEvent, id)

  def create_finance_event(attrs) do
    %FinanceEvent{}
    |> FinanceEvent.changeset(attrs)
    |> Repo.insert()
  end

  # Billers

  def list_billers(company_id, opts \\ []) do
    Biller
    |> where(company_id: ^company_id)
    |> maybe_filter(:is_active, opts[:is_active])
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  def get_biller!(id), do: Repo.get!(Biller, id)

  def get_biller(id) do
    case Repo.get(Biller, id) do
      nil -> {:error, :not_found}
      biller -> {:ok, biller}
    end
  end

  def create_biller(attrs) do
    %Biller{}
    |> Biller.changeset(attrs)
    |> Repo.insert()
  end

  def update_biller(%Biller{} = biller, attrs) do
    biller
    |> Biller.changeset(attrs)
    |> Repo.update()
  end

  def delete_biller(%Biller{} = biller) do
    Repo.delete(biller)
  end

  # Work Products

  def list_work_products(issue_id) do
    WorkProduct
    |> where(issue_id: ^issue_id)
    |> order_by(asc: :inserted_at)
    |> Repo.all()
  end

  def get_work_product!(id), do: Repo.get!(WorkProduct, id)

  def create_work_product(attrs) do
    %WorkProduct{}
    |> WorkProduct.changeset(attrs)
    |> Repo.insert()
  end

  def delete_work_product(%WorkProduct{} = work_product) do
    Repo.delete(work_product)
  end

  # Private helpers

  defp maybe_filter(query, _field, nil), do: query

  defp maybe_filter(query, field, value), do: where(query, [t], field(t, ^field) == ^value)

  defp maybe_paginate(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)
    query |> limit(^limit) |> offset(^offset)
  end

  defp filter_by_period(query, "daily", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, "weekly", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, "monthly", from, _to) when not is_nil(from) do
    where(query, [t], t.inserted_at >= ^from)
  end

  defp filter_by_period(query, _period, _from, _to), do: query

  defp check_budget_thresholds(%TokenUsage{} = token_usage) do
    token_usage.company_id
    |> active_budget_policies()
    |> Enum.filter(&policy_applies_to_usage?(&1, token_usage))
    |> Enum.reduce_while(
      {:ok, %{blocked_policies: [], incidents: []}},
      fn policy, {:ok, evaluation} ->
        # The policy lock serializes spend aggregation and incident creation
        # for concurrent provider callbacks in the same scope.
        locked_policy =
          from(p in BudgetPolicy, where: p.id == ^policy.id, lock: "FOR UPDATE")
          |> Repo.one!()

        case check_policy_threshold(locked_policy, token_usage) do
          {:ok, %{blocked?: blocked?, incident: incident, spend: spend}} ->
            evaluation =
              evaluation
              |> maybe_add_incident(incident)
              |> maybe_add_blocked_policy(blocked?, locked_policy, spend)

            {:cont, {:ok, evaluation}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end
    )
  end

  defp check_policy_threshold(policy, token_usage) do
    current_spend = policy_spend(policy)

    threshold_pct =
      Decimal.mult(
        Decimal.new(100),
        Decimal.div(current_spend, policy.budget_limit_usd)
      )

    cond do
      not Decimal.lt?(current_spend, policy.budget_limit_usd) ->
        with {:ok, incident} <-
               ensure_incident(
                 policy,
                 token_usage,
                 "budget_exceeded",
                 current_spend,
                 threshold_pct
               ) do
          {:ok,
           %{
             blocked?: policy.action_on_exceed == "block",
             incident: incident,
             spend: current_spend
           }}
        end

      Decimal.gt?(threshold_pct, policy.warning_threshold_pct) ->
        with {:ok, incident} <-
               ensure_incident(policy, token_usage, "warning", current_spend, threshold_pct) do
          {:ok, %{blocked?: false, incident: incident, spend: current_spend}}
        end

      true ->
        {:ok, %{blocked?: false, incident: nil, spend: current_spend}}
    end
  end

  defp ensure_incident(policy, token_usage, event_type, spend, threshold_pct) do
    existing =
      Repo.one(
        from i in BudgetIncident,
          where:
            i.budget_policy_id == ^policy.id and i.event_type == ^event_type and
              is_nil(i.resolved_at),
          order_by: [desc: i.inserted_at],
          limit: 1
      )

    if existing do
      {:ok, existing}
    else
      %BudgetIncident{}
      |> BudgetIncident.changeset(%{
        budget_policy_id: policy.id,
        company_id: token_usage.company_id,
        event_type: event_type,
        spend_usd: spend,
        budget_limit_usd: policy.budget_limit_usd,
        threshold_pct: threshold_pct,
        metadata: %{
          "token_usage_id" => token_usage.id,
          "scope" => policy.scope,
          "scope_id" => policy.scope_id,
          "action_on_exceed" => policy.action_on_exceed
        }
      })
      |> Repo.insert()
    end
  end

  defp maybe_add_incident(evaluation, nil), do: evaluation

  defp maybe_add_incident(evaluation, incident),
    do: Map.update!(evaluation, :incidents, &[incident | &1])

  defp existing_heartbeat_run_usage(attrs, changeset) do
    heartbeat_run_id = Map.get(attrs, :heartbeat_run_id) || Map.get(attrs, "heartbeat_run_id")
    company_id = Map.get(attrs, :company_id) || Map.get(attrs, "company_id")

    duplicate_run? =
      Enum.any?(changeset.errors, fn
        {:heartbeat_run_id, {_message, opts}} -> opts[:constraint] == :unique
        _error -> false
      end)

    if duplicate_run? and is_binary(heartbeat_run_id) and is_binary(company_id) do
      Repo.get_by(TokenUsage, heartbeat_run_id: heartbeat_run_id, company_id: company_id)
    end
  end

  defp validate_heartbeat_run_scope(attrs) do
    case Map.get(attrs, :heartbeat_run_id) || Map.get(attrs, "heartbeat_run_id") do
      nil ->
        :ok

      heartbeat_run_id when is_binary(heartbeat_run_id) ->
        case Repo.get(Run, heartbeat_run_id) do
          %Run{} = run -> validate_usage_run_ids(attrs, run)
          nil -> {:error, :heartbeat_run_not_found}
        end

      _heartbeat_run_id ->
        {:error, :heartbeat_run_not_found}
    end
  end

  defp validate_usage_run_ids(attrs, %Run{} = run) do
    company_id = Map.get(attrs, :company_id) || Map.get(attrs, "company_id")
    agent_id = Map.get(attrs, :agent_id) || Map.get(attrs, "agent_id")
    issue_id = Map.get(attrs, :issue_id) || Map.get(attrs, "issue_id")
    project_id = Map.get(attrs, :project_id) || Map.get(attrs, "project_id")
    goal_id = Map.get(attrs, :goal_id) || Map.get(attrs, "goal_id")

    case Repo.get(Issue, run.issue_id) do
      %Issue{} = issue ->
        expected_company_id = issue.company_id || run.company_id

        if company_id == expected_company_id and
             agent_id == run.agent_id and
             issue_id == run.issue_id and
             project_id == issue.project_id and
             goal_id == issue.goal_id do
          :ok
        else
          {:error, :heartbeat_run_scope_mismatch}
        end

      nil ->
        {:error, :heartbeat_run_scope_mismatch}
    end
  end

  defp maybe_add_blocked_policy(evaluation, false, _policy, _spend), do: evaluation

  defp maybe_add_blocked_policy(evaluation, true, policy, spend) do
    Map.update!(evaluation, :blocked_policies, &[%{policy: policy, spend: spend} | &1])
  end

  defp enforce_hard_stops(blocked_policies) do
    blocked_policies
    |> Enum.uniq_by(& &1.policy.id)
    |> Enum.sort_by(&hard_stop_order/1)
    |> Enum.each(&safely_enforce_hard_stop/1)
  end

  # Stop issue-level work before pausing agents, and pause the whole company
  # last. Dispatcher cleanup can idle an assignee, so this ordering preserves
  # the strongest final pause when one usage crosses multiple policies.
  defp hard_stop_order(%{policy: %BudgetPolicy{scope: scope}})
       when scope in ["issue", "project", "goal"],
       do: 0

  defp hard_stop_order(%{policy: %BudgetPolicy{scope: "agent"}}), do: 1
  defp hard_stop_order(%{policy: %BudgetPolicy{scope: "company"}}), do: 2
  defp hard_stop_order(_blocked), do: 3

  defp safely_enforce_hard_stop(%{policy: %BudgetPolicy{} = policy} = blocked) do
    enforce_hard_stop(blocked)
  rescue
    error ->
      log_hard_stop_failure(policy, :enforcement, error, __STACKTRACE__)
  catch
    kind, reason ->
      log_hard_stop_failure(policy, :enforcement, {kind, reason}, __STACKTRACE__)
  end

  defp enforce_hard_stop(
         %{
           policy:
             %BudgetPolicy{scope: "agent", scope_id: agent_id, company_id: company_id} = policy
         } = blocked
       )
       when is_binary(agent_id) do
    reason =
      "Budget hard stop #{policy.id}: agent spend #{Decimal.to_string(blocked.spend)} USD exceeded #{Decimal.to_string(policy.budget_limit_usd)} USD. Raise or resolve the budget before resuming."

    case Agents.get_agent(agent_id) do
      {:ok, %{company_id: ^company_id}} ->
        active_agent_issue_ids(company_id, agent_id)
        |> Enum.each(fn issue_id ->
          run_hard_stop_step(policy, :stop_agent_runtime, fn ->
            Dispatcher.stop_issue(issue_id, reason)
          end)
        end)

        # Keep exact agent-run cleanup independent from dispatcher/orchestrator
        # shutdown so a partial stop cannot leave a provider turn alive.
        run_hard_stop_step(policy, :cancel_agent_runs, fn ->
          HeartbeatEngine.cancel_active_runs_for_agent(company_id, agent_id, reason)
        end)

        run_hard_stop_step(policy, :cancel_agent_wakes, fn ->
          Wakes.cancel_agent_wakes(agent_id, reason)
        end)

        run_hard_stop_step(policy, :pause_agent, fn -> Agents.pause_agent(agent_id, reason) end)

      {:ok, _other_company_agent} ->
        log_hard_stop_failure(policy, :load_agent, :company_mismatch)

      {:error, reason} ->
        log_hard_stop_failure(policy, :load_agent, reason)
    end
  end

  defp enforce_hard_stop(
         %{policy: %BudgetPolicy{scope: "company", company_id: company_id} = policy} = blocked
       ) do
    reason = hard_stop_reason(policy, blocked.spend)

    run_hard_stop_step(policy, :stop_company_runtime, fn ->
      case Repo.get(Company, company_id) do
        %Company{} = company -> Companies.stop_company_runtime(company, reason)
        nil -> {:error, :company_not_found}
      end
    end)

    # Companies.stop_company_runtime/2 already delegates here. A second
    # idempotent attempt gives a transient/partial dispatcher failure one more
    # chance without coupling it to the durable company pause update.
    run_hard_stop_step(policy, :confirm_company_runtime_stopped, fn ->
      Dispatcher.stop_company(company_id, reason)
    end)

    # Keep wake cleanup independent from the company status update/dispatcher
    # stop so a partial runtime-control failure cannot leave queued work alive.
    run_hard_stop_step(policy, :cancel_company_wakes, fn ->
      Wakes.cancel_company_wakes(company_id, reason)
    end)
  end

  defp enforce_hard_stop(
         %{policy: %BudgetPolicy{scope: "issue", scope_id: issue_id} = policy} = blocked
       )
       when is_binary(issue_id) do
    reason = hard_stop_reason(policy, blocked.spend)

    case scoped_issue(policy.company_id, issue_id) do
      %Issue{} = issue ->
        run_hard_stop_step(policy, :pause_issue_runtime, fn ->
          Issues.pause_issue_runtime(issue, reason: reason)
        end)

        stop_issue_runtime(policy, issue_id, reason)

      nil ->
        log_hard_stop_failure(policy, :load_issue, :issue_not_found)
    end
  end

  defp enforce_hard_stop(
         %{policy: %BudgetPolicy{scope: scope, scope_id: scope_id} = policy} = blocked
       )
       when scope in ["project", "goal"] and is_binary(scope_id) do
    reason = hard_stop_reason(policy, blocked.spend)

    policy
    |> open_scope_issue_ids()
    |> Enum.each(&stop_issue_runtime(policy, &1, reason))
  end

  defp enforce_hard_stop(%{policy: %BudgetPolicy{} = policy}) do
    Logger.error("Finances: hard stop committed but policy scope cannot be enforced",
      budget_policy_id: policy.id,
      company_id: policy.company_id,
      scope: policy.scope,
      scope_id: policy.scope_id
    )
  end

  defp stop_issue_runtime(policy, issue_id, reason) do
    run_hard_stop_step(policy, :stop_issue_runtime, fn ->
      Dispatcher.stop_issue(issue_id, reason)
    end)

    # Keep run cancellation independent from orchestrator/checkout cleanup.
    # It is idempotent after a successful Dispatcher.stop_issue/2 and remains
    # effective if that broader stop fails partway through.
    run_hard_stop_step(policy, :cancel_issue_runs, fn ->
      HeartbeatEngine.cancel_active_runs_for_issue(issue_id, reason)
    end)

    run_hard_stop_step(policy, :cancel_issue_wakes, fn ->
      Wakes.cancel_issue_wakes(issue_id, reason)
    end)
  end

  defp scoped_issue(company_id, issue_id) do
    Repo.one(from i in Issue, where: i.company_id == ^company_id and i.id == ^issue_id)
  end

  defp active_agent_issue_ids(company_id, agent_id) do
    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.assignee_id == ^agent_id and i.status == :in_progress)
    |> select([i], i.id)
    |> Repo.all()
  end

  defp open_scope_issue_ids(%BudgetPolicy{
         company_id: company_id,
         scope: scope,
         scope_id: scope_id
       }) do
    scope_field = String.to_existing_atom("#{scope}_id")

    Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], field(i, ^scope_field) == ^scope_id)
    |> where([i], i.status not in [:done, :cancelled])
    |> select([i], i.id)
    |> Repo.all()
  end

  defp run_hard_stop_step(%BudgetPolicy{} = policy, step, callback) do
    case callback.() do
      :ok ->
        :ok

      {:ok, _updated, %{errors: errors}} when is_list(errors) and errors != [] ->
        log_hard_stop_failure(policy, step, {:partial_failure, errors})

      {:ok, _updated, _result} ->
        :ok

      {:ok, %{errors: errors}} when is_list(errors) and errors != [] ->
        log_hard_stop_failure(policy, step, {:partial_failure, errors})

      {:ok, _result} ->
        :ok

      {:error, reason} ->
        log_hard_stop_failure(policy, step, reason)

      other ->
        log_hard_stop_failure(policy, step, {:unexpected_result, other})
    end
  rescue
    error ->
      log_hard_stop_failure(policy, step, error, __STACKTRACE__)
  catch
    kind, reason ->
      log_hard_stop_failure(policy, step, {kind, reason}, __STACKTRACE__)
  end

  defp log_hard_stop_failure(policy, step, error, stacktrace \\ []) do
    Logger.error("Finances: budget hard-stop cleanup failed",
      budget_policy_id: policy.id,
      company_id: policy.company_id,
      scope: policy.scope,
      scope_id: policy.scope_id,
      step: step,
      error: Exception.format(:error, error, stacktrace)
    )
  end

  defp hard_stop_reason(policy, spend) do
    "Budget hard stop #{policy.id}: #{policy.scope} spend #{Decimal.to_string(spend)} USD reached #{Decimal.to_string(policy.budget_limit_usd)} USD. Raise or resolve the budget before resuming."
  end

  defp active_budget_policies(nil), do: []

  defp active_budget_policies(company_id) do
    BudgetPolicy
    |> where(company_id: ^company_id)
    |> where(is_active: true)
    |> Repo.all()
  end

  defp policy_applies_to_usage?(%BudgetPolicy{scope: "company"}, _token_usage), do: true

  defp policy_applies_to_usage?(%BudgetPolicy{scope: scope, scope_id: scope_id}, token_usage)
       when scope in ["agent", "project", "goal", "issue"] and is_binary(scope_id) do
    Map.get(token_usage, String.to_existing_atom("#{scope}_id")) == scope_id
  end

  defp policy_applies_to_usage?(_policy, _token_usage), do: false

  defp policy_applies_to_runtime?(%BudgetPolicy{scope: "company"}, _issue, _agent), do: true

  defp policy_applies_to_runtime?(
         %BudgetPolicy{scope: "agent", scope_id: scope_id},
         _issue,
         agent
       ),
       do: scope_id == Map.get(agent, :id)

  defp policy_applies_to_runtime?(
         %BudgetPolicy{scope: "project", scope_id: scope_id},
         issue,
         _agent
       ),
       do: scope_id == Map.get(issue, :project_id)

  defp policy_applies_to_runtime?(
         %BudgetPolicy{scope: "goal", scope_id: scope_id},
         issue,
         _agent
       ),
       do: scope_id == Map.get(issue, :goal_id)

  defp policy_applies_to_runtime?(
         %BudgetPolicy{scope: "issue", scope_id: scope_id},
         issue,
         _agent
       ),
       do: scope_id == Map.get(issue, :id)

  defp policy_applies_to_runtime?(_policy, _issue, _agent), do: false

  defp budget_exhausted?(%BudgetPolicy{} = policy),
    do: not Decimal.lt?(policy_spend(policy), policy.budget_limit_usd)

  defp policy_spend(%BudgetPolicy{} = policy) do
    TokenUsage
    |> where(company_id: ^policy.company_id)
    |> where([t], t.inserted_at >= ^period_start(policy.period))
    |> scope_query(policy)
    |> select([t], coalesce(sum(t.cost_usd), 0))
    |> Repo.one()
  end

  defp period_start("daily"), do: DateTime.utc_now() |> DateTime.add(-86400, :second)
  defp period_start("weekly"), do: DateTime.utc_now() |> DateTime.add(-604_800, :second)
  defp period_start("monthly"), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)
  defp period_start("yearly"), do: DateTime.utc_now() |> DateTime.add(-31_536_000, :second)
  defp period_start(_), do: DateTime.utc_now() |> DateTime.add(-2_592_000, :second)

  defp scope_query(query, %{scope: "company"}), do: query

  defp scope_query(query, %{scope: scope, scope_id: scope_id}) when not is_nil(scope_id) do
    field_atom = String.to_existing_atom("#{scope}_id")
    where(query, [t], field(t, ^field_atom) == ^scope_id)
  end

  defp scope_query(query, _), do: query
end
