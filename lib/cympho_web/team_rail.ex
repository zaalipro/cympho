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
  "N for you" per agent id.

  Seam for the Home step (A3): once the backend slice lands, this body becomes
  `OwnerAttention.counts(company_id, user).by_agent`, which also credits a
  review to the task's assignee. Until then it groups the Needs-you items by
  the agent that raised them.
  """
  def for_you_counts(company_id, user) do
    company_id
    |> OwnerAttention.list_items(user, limit: 500)
    |> Enum.frequencies_by(& &1.agent_id)
    |> Map.delete(nil)
  end

  @doc """
  The rail's spending slot, shown only at or above the warning threshold
  (80% of the limit by default) or once the limit is reached; nil otherwise.
  """
  def spend(company_id) when is_binary(company_id) do
    spent = Costs.summary(company_id, 30).total_cost

    case Costs.spend_posture(company_id, spent) do
      %{budget_status: status, budget_limit: %Decimal{} = limit} = posture
      when status in [:watch, :over_budget] ->
        %{
          paused?: status == :over_budget,
          spent: posture.budget_spend,
          limit: limit,
          percent: percent(posture.budget_spend, limit)
        }

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
