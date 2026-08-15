defmodule Cympho.Oversight.Patrol do
  @moduledoc """
  Periodic supervisor sweep that finds stuck issues and wakes the right
  agent to intervene.

  Different from `Cympho.HeartbeatEngine.Watchdog` (which recovers stale
  *runs* by marking them failed) and from `Cympho.ReviewNudges.StaleScanner`
  (which re-emits review nudges) — Patrol watches the issue's *workflow*
  state, not the run-level heartbeat. It's the missing layer between
  "agent crashed" and "agent silently stopped making progress."

  Routing rules:
    - in_progress / blocked stalled work → wake the assignee's parent
      agent (typically CTO for engineers, CEO for CTO), or fallback to
      the company CEO when no parent exists.
    - in_review stalled work → wake the issue's current assignee (the
      reviewer who hasn't picked it up), unless that assignee is
      paused/terminated — then escalate to parent/CEO.
    - unassigned stalled work → wake the manager that delegated it: the
      `monitor_state["decomposition_owner_id"]` that parked the issue, else
      the parent issue's assignee, else the company CEO.
    - root issue with no parent_id → wake the company CEO.
    - paused/terminated supervisors are never waked; resolution walks
      the parent chain then CEO, skipping dead agents.

  Dead-assignee fast path: non-terminal issues whose assignee is paused
  or terminated are treated as stuck immediately (no 30–120m wall-clock
  wait). Pause rehome usually clears the assignee, so this covers the
  residual window and any terminate path that did not rehome.

  Cooldown prevents the same supervisor from being re-poked every sweep
  for the same issue. The wake queue dedups on
  agent+issue+reason so this is mostly belt-and-suspenders.

  Disabled in tests via the `:start_oversight_patrol?` app env flag.
  """

  use GenServer
  import Ecto.Query, warn: false

  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Repo
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  require Logger

  @default_check_interval :timer.minutes(5)
  @non_terminal_statuses [:todo, :in_progress, :in_review, :blocked]
  @dead_governance_statuses ["paused", "terminated"]

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers an immediate patrol sweep."
  def sweep_now do
    case Process.whereis(__MODULE__) do
      nil ->
        {:error, :not_started}

      pid ->
        send(pid, :sweep)
        :ok
    end
  end

  @doc """
  Synchronously runs one patrol sweep across all (or selected) companies.
  Returns counters for telemetry/test assertions.
  """
  @spec sweep_companies(keyword()) :: %{
          companies: non_neg_integer(),
          stuck_found: non_neg_integer(),
          waked: non_neg_integer(),
          skipped_cooldown: non_neg_integer(),
          skipped_no_supervisor: non_neg_integer(),
          errors: non_neg_integer()
        }
  def sweep_companies(opts \\ []) do
    companies = list_companies(opts)

    Enum.reduce(
      companies,
      base_counters(length(companies)),
      fn company, acc ->
        try do
          merge_counters(acc, patrol_company(company.id, opts))
        rescue
          e ->
            Logger.warning(
              "[Oversight.Patrol] error patrolling company #{company.id}: #{Exception.message(e)}"
            )

            Map.update!(acc, :errors, &(&1 + 1))
        end
      end
    )
  end

  @doc """
  Patrols a single company, returning a counter delta the sweep merges.
  """
  @spec patrol_company(binary(), keyword()) :: map()
  def patrol_company(company_id, opts \\ []) when is_binary(company_id) do
    stuck = list_patrol_stuck_issues(company_id, opts)

    Enum.reduce(stuck, %{stuck_found: length(stuck)}, fn issue, acc ->
      case wake_supervisor_for(issue, opts) do
        :ok -> Map.update(acc, :waked, 1, &(&1 + 1))
        :cooldown -> Map.update(acc, :skipped_cooldown, 1, &(&1 + 1))
        :no_supervisor -> Map.update(acc, :skipped_no_supervisor, 1, &(&1 + 1))
        :error -> Map.update(acc, :errors, 1, &(&1 + 1))
      end
    end)
  end

  @doc """
  Returns the stuck-work candidates a patrol sweep would inspect without
  enqueuing any wakes.
  """
  @spec preview_company(binary(), keyword()) :: [
          %{issue: Issue.t(), supervisor: Agent.t() | nil, stale_minutes: integer() | nil}
        ]
  def preview_company(company_id, opts \\ []) when is_binary(company_id) do
    company_id
    |> list_patrol_stuck_issues(opts)
    |> Enum.map(fn issue ->
      %{
        issue: issue,
        supervisor: resolve_supervisor(issue),
        stale_minutes: stale_minutes(issue)
      }
    end)
  end

  @doc """
  Resolves the supervisor agent for a stuck issue and enqueues an
  `issue_stalled_in_progress` wake. Returns:
    `:ok` — wake enqueued
    `:cooldown` — same supervisor was waked recently for this issue
    `:no_supervisor` — no agent could be resolved
    `:error` — wake enqueue itself failed
  """
  @spec wake_supervisor_for(Issue.t(), keyword()) :: :ok | :cooldown | :no_supervisor | :error
  def wake_supervisor_for(%Issue{} = issue, opts \\ []) do
    cooldown_seconds = Keyword.get(opts, :cooldown_seconds, 300)

    case resolve_supervisor(issue) do
      nil ->
        :no_supervisor

      %Agent{id: supervisor_id} = supervisor ->
        cond do
          not agent_awakeable?(supervisor) ->
            :no_supervisor

          recent_stall_wake?(supervisor_id, issue.id, cooldown_seconds) ->
            :cooldown

          true ->
            metadata = %{
              "company_id" => issue.company_id,
              "stuck_status" => to_string(issue.status),
              "assignee_id" => issue.assignee_id,
              "stale_minutes" => stale_minutes(issue),
              "supervisor_role" => to_string(supervisor.role),
              "dead_assignee" => dead_assignee?(issue)
            }

            case Wakes.wake_for_stalled_issue(supervisor_id, issue.id, metadata) do
              {:ok, _wake} -> :ok
              {:error, _reason} -> :error
            end
        end
    end
  end

  ## Server callbacks

  @impl true
  def init(opts) do
    schedule_sweep(opts)
    {:ok, %{opts: opts, last_swept_at: nil}}
  end

  @impl true
  def handle_info(:sweep, state) do
    counters = sweep_companies(state.opts)

    if counters.waked > 0 or counters.errors > 0 do
      Logger.info("[Oversight.Patrol] sweep counters=#{inspect(counters)}")
    end

    schedule_sweep(state.opts)
    {:noreply, %{state | last_swept_at: DateTime.utc_now()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal — stuck candidate discovery

  # Union of time-threshold stuck issues and immediate dead-assignee issues.
  # Deduped by issue id so a dead assignee who is also past the staleness
  # window is only handled once.
  defp list_patrol_stuck_issues(company_id, opts) do
    timed = Issues.list_stuck_issues(company_id, opts)
    dead = list_dead_assignee_issues(company_id)

    timed
    |> Enum.concat(dead)
    |> Enum.uniq_by(& &1.id)
  end

  # Non-terminal issues whose assignee is paused or terminated are stuck
  # *now* — no wall-clock wait. Live runs are ignored: a paused agent cannot
  # make progress even if a zombie run row is still "running".
  defp list_dead_assignee_issues(company_id) do
    from(i in Issue,
      as: :issue,
      join: a in Agent,
      on: a.id == i.assignee_id,
      where: i.company_id == ^company_id,
      where: i.status in ^@non_terminal_statuses,
      where: is_nil(i.hidden_at),
      where: is_nil(i.origin_type) or i.origin_type != "backlog_planner",
      where:
        fragment(
          "COALESCE((? -> 'patrol' ->> 'excluded')::boolean, false) = false",
          i.monitor_state
        ),
      where:
        a.status in ^[:paused, :terminated] or
          a.governance_status in ^@dead_governance_statuses,
      order_by: [asc: i.updated_at]
    )
    |> Repo.all()
  end

  ## Internal — supervisor resolution

  # Pick the right agent to wake for a stuck issue. The rules are:
  #   :in_review   → wake the current assignee (the reviewer) if awakeable;
  #                  otherwise escalate to parent / CEO
  #   :in_progress → walk the parent chain from the assignee
  #   :blocked     → walk the parent chain from the assignee
  # In every case, fall back to an awakeable company CEO if the chain breaks.
  # Paused / terminated agents are never returned as the supervisor.
  defp resolve_supervisor(%Issue{
         status: :in_review,
         assignee_id: assignee_id,
         company_id: company_id
       })
       when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{} = agent} ->
        if agent_awakeable?(agent) do
          agent
        else
          parent_or_ceo(agent, company_id)
        end

      _ ->
        ceo_or_nil(company_id)
    end
  end

  defp resolve_supervisor(%Issue{assignee_id: assignee_id, company_id: company_id} = issue)
       when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{} = agent} ->
        parent_or_ceo(agent, company_id)

      _ ->
        delegating_manager(issue) || ceo_or_nil(company_id)
    end
  end

  # Unassigned. Before falling through to the CEO, ask who actually owns this
  # work: a manager that decomposed an issue parks it `:blocked` with no
  # assignee and records itself in `monitor_state`, and a delegated child names
  # its parent. Skipping straight to the CEO escalated a stalled CTO fan-out
  # one level too far — past the only agent holding the decomposition context.
  defp resolve_supervisor(%Issue{company_id: company_id} = issue),
    do: delegating_manager(issue) || ceo_or_nil(company_id)

  defp delegating_manager(%Issue{} = issue) do
    decomposition_owner(issue) || parent_issue_owner(issue)
  end

  defp decomposition_owner(%Issue{monitor_state: monitor_state} = issue) do
    case get_in(monitor_state || %{}, ["decomposition_owner_id"]) do
      id when is_binary(id) -> awakeable_agent(id, issue.company_id)
      _ -> nil
    end
  end

  defp parent_issue_owner(%Issue{parent_id: parent_id, company_id: company_id})
       when is_binary(parent_id) do
    case Repo.get(Issue, parent_id) do
      %Issue{assignee_id: assignee_id} when is_binary(assignee_id) ->
        awakeable_agent(assignee_id, company_id)

      _ ->
        nil
    end
  end

  defp parent_issue_owner(%Issue{}), do: nil

  # Fail-closed: a supervisor must belong to the issue's company, so a stale
  # monitor_state id can never wake an agent in another tenant.
  defp awakeable_agent(agent_id, company_id) when is_binary(company_id) do
    case Agents.get_agent(agent_id) do
      {:ok, %Agent{company_id: ^company_id} = agent} ->
        if agent_awakeable?(agent), do: agent, else: nil

      _ ->
        nil
    end
  end

  defp awakeable_agent(_agent_id, _company_id), do: nil

  defp parent_or_ceo(%Agent{parent_id: parent_id} = agent, company_id)
       when is_binary(parent_id) do
    case Agents.get_agent(parent_id) do
      {:ok, %Agent{} = parent} ->
        if agent_awakeable?(parent) do
          parent
        else
          # Parent is dead — try their parent, else company CEO.
          parent_or_ceo(parent, company_id || agent.company_id)
        end

      _ ->
        ceo_or_nil(company_id || agent.company_id)
    end
  end

  defp parent_or_ceo(%Agent{company_id: company_id}, _company_id), do: ceo_or_nil(company_id)

  defp ceo_or_nil(nil), do: nil

  defp ceo_or_nil(company_id) when is_binary(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %Agent{} = ceo} ->
        if agent_awakeable?(ceo), do: ceo, else: nil

      _ ->
        nil
    end
  end

  defp agent_awakeable?(%Agent{status: status}) when status in [:paused, :terminated], do: false

  defp agent_awakeable?(%Agent{governance_status: status})
       when status in ["paused", "terminated", "pending_approval"],
       do: false

  defp agent_awakeable?(%Agent{}), do: true

  defp dead_assignee?(%Issue{assignee_id: nil}), do: false

  defp dead_assignee?(%Issue{assignee_id: assignee_id}) when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{} = agent} -> not agent_awakeable?(agent)
      _ -> false
    end
  end

  ## Internal — schedule + cooldown + counters

  defp schedule_sweep(opts) do
    interval = Keyword.get(opts, :check_interval_ms, @default_check_interval)
    Process.send_after(self(), :sweep, interval)
  end

  defp recent_stall_wake?(supervisor_id, issue_id, cooldown_seconds) do
    cutoff = DateTime.utc_now() |> DateTime.add(-cooldown_seconds, :second)

    Repo.exists?(
      from w in AgentWake,
        where:
          w.agent_id == ^supervisor_id and
            w.issue_id == ^issue_id and
            w.reason == "issue_stalled_in_progress" and
            w.inserted_at > ^cutoff
    )
  end

  defp stale_minutes(%Issue{checked_out_at: nil, updated_at: updated_at}),
    do: stale_minutes_from(updated_at)

  defp stale_minutes(%Issue{status: :in_progress, checked_out_at: checked_out_at}),
    do: stale_minutes_from(checked_out_at)

  defp stale_minutes(%Issue{updated_at: updated_at}), do: stale_minutes_from(updated_at)

  defp stale_minutes_from(nil), do: nil

  defp stale_minutes_from(%DateTime{} = ts),
    do: div(DateTime.diff(DateTime.utc_now(), ts, :second), 60)

  defp list_companies(opts) do
    case Keyword.get(opts, :company_ids) do
      ids when is_list(ids) ->
        Repo.all(from c in Companies.Company, where: c.id in ^ids)

      _ ->
        Companies.list_companies()
        |> Enum.filter(&Companies.active?/1)
    end
  end

  defp base_counters(n_companies) do
    %{
      companies: n_companies,
      stuck_found: 0,
      waked: 0,
      skipped_cooldown: 0,
      skipped_no_supervisor: 0,
      errors: 0
    }
  end

  defp merge_counters(acc, delta) do
    Enum.reduce(delta, acc, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 + v)) end)
  end
end
