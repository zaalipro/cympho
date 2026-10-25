defmodule CymphoWeb.TeamRail do
  @moduledoc """
  Data for the live team list (the rail's `CymphoWeb.TeamRailLive`, and Home's
  phone team block) and for the rail's spending slot. Company-scoped reads only.
  """

  alias Cympho.Agents
  alias Cympho.Costs
  alias Cympho.HeartbeatEngine
  alias Cympho.OwnerAttention
  alias Cympho.Repo

  @doc """
  One row per active agent of the company, ordered: stopped or paused agents
  first, then agents with items for you, then the rest, each alphabetical.

  `detail: true` adds what a Working agent is doing (one run lookup per
  Working agent); the rail does not show it, Home's phone team block does.
  """
  def rows(company_id, user, opts \\ [])

  def rows(company_id, user, opts) when is_binary(company_id) do
    counts = for_you_counts(company_id, user)
    detail? = Keyword.get(opts, :detail, false)

    company_id
    |> Agents.list_for_sidebar()
    |> Enum.map(&row(&1, Map.get(counts, &1.id, 0), detail?))
    |> Enum.sort_by(&{rank(&1), String.downcase(&1.name)})
  end

  def rows(_company_id, _user, _opts), do: []

  @doc """
  "N for you" per agent id, from the same unlimited membership as the Inbox
  badge (`OwnerAttention.counts/2`): a review or a blocked task counts for the
  task's assignee. The chips add up to the badge whenever every item has an
  agent (a budget incident, a task waiting on a person or an unassigned
  blocked task has none).
  """
  def for_you_counts(company_id, user) do
    OwnerAttention.counts(company_id, user).by_agent
  end

  @doc """
  Spend against the company's limit over the limit's own window
  (`Costs.spend_period/1`, 30 days for a monthly limit): the one read behind
  the rail's spending slot and Home's limit line, so the two never disagree.
  `limit`, `percent` and `used_percent` are nil when no comparable limit is set.
  """
  def spending(company_id) when is_binary(company_id) do
    days = Costs.spend_period(company_id).days
    posture = Costs.spend_posture(company_id, Costs.summary(company_id, days).total_cost)
    limit = posture.budget_limit

    %{
      spent: posture.budget_spend,
      limit: limit,
      days: days,
      percent: limit && percent(posture.budget_spend, limit),
      used_percent: posture.budget_used_percent,
      warn_percent:
        posture.budget_warning_threshold_pct |> Decimal.round(0) |> Decimal.to_integer(),
      status: posture.budget_status
    }
  end

  @doc """
  The rail's spending slot, shown only at or above the warning threshold
  (80% of the limit by default) or once the limit is reached; nil otherwise.
  """
  def spend(company_id) when is_binary(company_id) do
    case spending(company_id) do
      %{status: status, limit: %Decimal{}} = spending when status in [:watch, :over_budget] ->
        Map.put(spending, :paused?, status == :over_budget)

      _ ->
        nil
    end
  end

  def spend(_company_id), do: nil

  defp row(agent, for_you, detail?) do
    {kind, word} = status(agent.status)

    %{
      id: agent.id,
      name: agent.name,
      href: "/agents/#{agent.id}",
      kind: kind,
      word: word,
      for_you: for_you,
      pin: kind == :stopped,
      detail: if(detail? and kind == :working, do: working_detail(agent.id))
    }
  end

  # Spec §1.5: one word per state, with its shape.
  defp status(status) when status in [:running, :active], do: {:working, "Working"}
  defp status(:error), do: {:stopped, "Stopped"}
  defp status(:paused), do: {:stopped, "Paused"}
  defp status(:pending_approval), do: {:waiting, "Waiting for your approval"}
  defp status(:offline), do: {:idle, "Offline"}
  defp status(_idle_or_sleeping), do: {:idle, "Idle"}

  defp rank(%{kind: :stopped}), do: 0
  defp rank(%{for_you: n}) when n > 0, do: 1
  defp rank(_row), do: 2

  # What a Working agent is doing now, from its running run: "reviewing NW-9 · 28 min".
  defp working_detail(agent_id) do
    case HeartbeatEngine.get_active_run_for_agent(agent_id) do
      {:ok, run} ->
        run = Repo.preload(run, :issue)

        minutes =
          if run.started_at, do: DateTime.diff(DateTime.utc_now(), run.started_at, :minute)

        Enum.join(
          Enum.reject([run_subject(run.issue), minutes && "#{minutes} min"], &is_nil/1),
          " · "
        )

      _ ->
        nil
    end
  end

  defp run_subject(%{status: :in_review, identifier: id}) when is_binary(id),
    do: "reviewing #{id}"

  defp run_subject(%{identifier: id}) when is_binary(id), do: "on #{id}"
  defp run_subject(_issue), do: nil

  defp percent(spent, limit) do
    if Decimal.gt?(limit, 0),
      do: spent |> Decimal.div(limit) |> Decimal.mult(100) |> Decimal.to_float(),
      else: 0
  end
end
