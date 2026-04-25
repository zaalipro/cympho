defmodule Cympho.Dashboard do
  @moduledoc """
  Company-wide dashboard metrics.

  All functions are pure queries against existing schemas — no new tables needed.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  def active_agents_count do
    Repo.one(
      from a in Agent,
        where: a.status in [:idle, :running],
        select: count(a.id)
    )
  end

  def total_agents_count do
    Repo.one(from a in Agent, select: count(a.id))
  end

  def issues_created_per_day(days \\ 7) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Repo.all(
      from i in Issue,
        where: i.inserted_at >= ^since,
        group_by: fragment("date(?)", i.inserted_at),
        order_by: fragment("date(?)", i.inserted_at),
        select: %{
          date: fragment("date(?)", i.inserted_at),
          count: count(i.id)
        }
    )
  end

  def issues_closed_per_day(days \\ 7) do
    since = DateTime.utc_now() |> DateTime.add(-days * 86400, :second)

    Repo.all(
      from i in Issue,
        where: i.status == :done and i.updated_at >= ^since,
        group_by: fragment("date(?)", i.updated_at),
        order_by: fragment("date(?)", i.updated_at),
        select: %{
          date: fragment("date(?)", i.updated_at),
          count: count(i.id)
        }
    )
  end

  def bottleneck_issues(stale_days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.add(-stale_days * 86400, :second)

    Repo.all(
      from i in Issue,
        where: i.status == :in_review and i.updated_at < ^cutoff,
        order_by: [asc: i.updated_at],
        preload: [:assignee, :project],
        limit: 20
    )
  end

  def issue_status_counts do
    Repo.all(
      from i in Issue,
        group_by: i.status,
        select: %{status: i.status, count: count(i.id)}
    )
  end

  def agent_status_counts do
    Repo.all(
      from a in Agent,
        group_by: a.status,
        select: %{status: a.status, count: count(a.id)}
    )
  end

  def summary do
    %{
      active_agents: active_agents_count(),
      total_agents: total_agents_count(),
      agent_status_counts: agent_status_counts(),
      issue_status_counts: issue_status_counts(),
      throughput: %{
        created: issues_created_per_day(),
        closed: issues_closed_per_day()
      },
      bottlenecks: Enum.map(bottleneck_issues(), &bottle_neck_to_map/1),
      routine_health: routine_health(),
      recent_activities: recent_activities(10),
      cost_summary: cost_summary()
    }
  end

  def recent_activities(limit \\ 20) do
    import Ecto.Query

    try do
      Cympho.Activities.Activity
      |> order_by([a], desc: a.inserted_at)
      |> limit(^limit)
      |> Repo.all()
    rescue
      _ -> []
    end
  end

  def cost_summary do
    import Ecto.Query

    try do
      runs = Cympho.HeartbeatEngine.Run
        |> where([r], r.status == "completed")
        |> Repo.all()

      total_cost = Enum.reduce(runs, Decimal.new(0), fn run, acc ->
        cost = run.cost_usd || Decimal.new(0)
        Decimal.add(acc, cost)
      end)

      total_input = Enum.reduce(runs, 0, fn run, acc ->
        acc + (run.input_tokens || 0)
      end)

      total_output = Enum.reduce(runs, 0, fn run, acc ->
        acc + (run.output_tokens || 0)
      end)

      %{
        total_cost: total_cost,
        total_input_tokens: total_input,
        total_output_tokens: total_output,
        total_runs: length(runs)
      }
    rescue
      _ -> %{
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
