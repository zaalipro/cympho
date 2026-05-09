defmodule Cympho.Dashboard do
  @moduledoc """
  Company-wide dashboard metrics.

  All functions are pure queries against existing schemas — no new tables needed.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Issues.Issue
  alias Cympho.RuntimeCapacity

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
      active_agent_list: Enum.map(active_agents(company_id), &agent_to_map/1),
      agent_status_counts: agent_status_counts(company_id),
      issue_status_counts: issue_status_counts(company_id),
      throughput: %{
        created: issues_created_per_day(7, company_id),
        closed: issues_closed_per_day(7, company_id)
      },
      bottlenecks: Enum.map(bottleneck_issues(7, company_id), &bottle_neck_to_map/1),
      routine_health: routine_health(),
      recent_activities: Enum.map(recent_activities(10, company_id), &activity_to_map/1),
      recent_inbox: Enum.map(recent_inbox(company_id, 6), &inbox_to_map/1),
      cost_summary: cost_summary(company_id),
      runtime_capacity: runtime_capacity(company_id)
    }
  end

  def empty_summary do
    %{
      active_agents: 0,
      total_agents: 0,
      active_agent_list: [],
      agent_status_counts: [],
      issue_status_counts: [],
      throughput: %{created: [], closed: []},
      bottlenecks: [],
      routine_health: routine_health(),
      recent_activities: [],
      recent_inbox: [],
      cost_summary: %{total_cost: Decimal.new(0), run_count: 0},
      runtime_capacity: RuntimeCapacity.company([])
    }
  end

  def runtime_capacity(company_id \\ nil) do
    agents =
      Agent
      |> scoped(company_id)
      |> where([a], a.status != :terminated)
      |> where([a], a.governance_status != "terminated")
      |> Repo.all()

    running_counts =
      Run
      |> scoped(company_id)
      |> where([r], r.status in ["running", "queued", "pending"])
      |> group_by([r], r.agent_id)
      |> select([r], {r.agent_id, count(r.id)})
      |> Repo.all()
      |> Map.new()

    RuntimeCapacity.company(agents, running_counts)
  rescue
    _ ->
      RuntimeCapacity.company([])
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
      identifier: issue.identifier,
      status: issue.status,
      updated_at: issue.updated_at,
      assignee: assoc_name(issue, :assignee),
      project: assoc_name(issue, :project)
    }
  end

  defp assoc_name(struct, key) do
    case Map.get(struct, key) do
      %{name: name} -> name
      _ -> nil
    end
  end

  defp agent_to_map(agent) do
    %{
      id: agent.id,
      name: agent.name,
      title: agent.title,
      role: agent.role,
      status: agent.status,
      adapter: agent.adapter,
      url_key: agent.url_key
    }
  end

  defp inbox_to_map(item) do
    %{
      id: item.id,
      agent_id: item.agent_id,
      issue_id: item.issue_id,
      status: item.status,
      agent: item.agent && agent_to_map(item.agent),
      issue: item.issue && bottle_neck_to_map(item.issue),
      inserted_at: item.inserted_at,
      updated_at: item.updated_at
    }
  end

  defp activity_to_map(activity) do
    %{
      id: activity.id,
      actor_type: activity.actor_type,
      actor_id: activity.actor_id,
      action: activity.action,
      issue_id: activity.issue_id,
      metadata: activity.metadata,
      inserted_at: activity.inserted_at
    }
  end
end
