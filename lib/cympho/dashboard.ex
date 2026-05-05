defmodule Cympho.Dashboard do
  @moduledoc """
  Company-wide dashboard metrics.

  All functions are pure queries against existing schemas — no new tables needed.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  def active_agents_count(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> where([a], a.status in [:idle, :running, :active])
    |> select([a], count(a.id))
    |> Repo.one()
  end

  def total_agents_count(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> select([a], count(a.id))
    |> Repo.one()
  end

  def issues_created_per_day(days \\ 7, company_id \\ nil) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.inserted_at >= ^since)
    |> group_by([i], fragment("date(?)", i.inserted_at))
    |> order_by([i], fragment("date(?)", i.inserted_at))
    |> select([i], %{
      date: fragment("date(?)", i.inserted_at),
      count: count(i.id)
    })
    |> Repo.all()
  end

  def issues_closed_per_day(days \\ 7, company_id \\ nil) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.status == :done and i.updated_at >= ^since)
    |> group_by([i], fragment("date(?)", i.updated_at))
    |> order_by([i], fragment("date(?)", i.updated_at))
    |> select([i], %{
      date: fragment("date(?)", i.updated_at),
      count: count(i.id)
    })
    |> Repo.all()
  end

  def bottleneck_issues(stale_days \\ 7, company_id \\ nil) do
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days * 86400, :second)

    Issue
    |> scoped(company_id)
    |> where([i], i.status == :in_review and i.updated_at < ^cutoff)
    |> order_by([i], asc: i.updated_at)
    |> preload([:assignee, :project])
    |> limit(20)
    |> Repo.all()
  end

  def issue_status_counts(company_id \\ nil) do
    Issue
    |> scoped(company_id)
    |> group_by([i], i.status)
    |> select([i], %{status: i.status, count: count(i.id)})
    |> Repo.all()
  end

  def agent_status_counts(company_id \\ nil) do
    Agent
    |> scoped(company_id)
    |> group_by([a], a.status)
    |> select([a], %{status: a.status, count: count(a.id)})
    |> Repo.all()
  end

  def active_agents(company_id \\ nil, limit \\ 8) do
    Agent
    |> scoped(company_id)
    |> where([a], a.status in [:idle, :running, :active, :error, :paused])
    |> order_by([a],
      asc:
        fragment(
          "CASE ? WHEN 'running' THEN 0 WHEN 'idle' THEN 1 WHEN 'error' THEN 2 ELSE 3 END",
          a.status
        ),
      asc: fragment("CASE ? WHEN 'ceo' THEN 0 WHEN 'cto' THEN 1 ELSE 2 END", a.role),
      asc: a.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def summary(company_id \\ nil) do
    %{
      active_agents: active_agents_count(company_id),
      total_agents: total_agents_count(company_id),
      active_agent_list: active_agents(company_id),
      agent_status_counts: agent_status_counts(company_id),
      issue_status_counts: issue_status_counts(company_id),
      throughput: %{
        created: issues_created_per_day(7, company_id),
        closed: issues_closed_per_day(7, company_id)
      },
      bottlenecks: Enum.map(bottleneck_issues(7, company_id), &bottle_neck_to_map/1),
      routine_health: routine_health(),
      recent_activities: recent_activities(10, company_id),
      recent_inbox: recent_inbox(company_id, 6),
      cost_summary: cost_summary(company_id)
    }
  end

  def recent_inbox(nil, _limit), do: []

  def recent_inbox(company_id, limit) do
    Cympho.Inbox.list_recent_for_company(company_id, limit: limit)
  rescue
    _ -> []
  end

  def recent_activities(limit \\ 20, company_id \\ nil) do
    import Ecto.Query

    try do
      Cympho.Activities.Activity
      |> scoped(company_id)
      |> order_by([a], desc: a.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    rescue
      _ -> []
    end
  end

  def cost_summary(company_id \\ nil) do
    import Ecto.Query

    try do
      runs =
        Cympho.HeartbeatEngine.Run
        |> scoped(company_id)
        |> where([r], r.status in ["completed", "succeeded"])
        |> Repo.all()

      total_cost =
        Enum.reduce(runs, Decimal.new(0), fn run, acc ->
          cost = run.cost_usd || Decimal.new(0)
          Decimal.add(acc, cost)
        end)

      total_input =
        Enum.reduce(runs, 0, fn run, acc ->
          acc + (run.input_tokens || 0)
        end)

      total_output =
        Enum.reduce(runs, 0, fn run, acc ->
          acc + (run.output_tokens || 0)
        end)

      %{
        total_cost: total_cost,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_runs: length(runs)
      }
    rescue
      _ ->
        %{
          total_cost: Decimal.new(0),
          total_input_tokens: 0,
          total_output_tokens: 0,
          total_runs: 0
        }
    end
  end

  def routine_health do
    %{status: "unavailable", message: "Routine execution tracking not yet configured"}
  end

  defp scoped(query, nil), do: query
  defp scoped(query, company_id), do: where(query, [q], q.company_id == ^company_id)

  defp bottle_neck_to_map(issue) do
    %{
      id: issue.id,
      title: issue.title,
      status: issue.status,
      updated_at: issue.updated_at,
      assignee: issue.assignee && issue.assignee.name,
      project: issue.project && issue.project.name
    }
  end
end
