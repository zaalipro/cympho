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
      reviewer who hasn't picked it up).
    - root issue with no parent_id → wake the company CEO.

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
    stuck = Issues.list_stuck_issues(company_id, opts)

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
          recent_stall_wake?(supervisor_id, issue.id, cooldown_seconds) ->
            :cooldown

          true ->
            metadata = %{
              "company_id" => issue.company_id,
              "stuck_status" => to_string(issue.status),
              "assignee_id" => issue.assignee_id,
              "stale_minutes" => stale_minutes(issue),
              "supervisor_role" => to_string(supervisor.role)
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

  ## Internal — supervisor resolution

  # Pick the right agent to wake for a stuck issue. The rules are:
  #   :in_review   → wake the current assignee (the reviewer)
  #   :in_progress → walk the parent chain from the assignee
  #   :blocked     → walk the parent chain from the assignee
  # In every case, fall back to the company CEO if the chain breaks.
  defp resolve_supervisor(%Issue{status: :in_review, assignee_id: assignee_id, company_id: company_id})
       when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{} = agent} -> agent
      _ -> ceo_or_nil(company_id)
    end
  end

  defp resolve_supervisor(%Issue{assignee_id: assignee_id, company_id: company_id})
       when is_binary(assignee_id) do
    case Agents.get_agent(assignee_id) do
      {:ok, %Agent{parent_id: parent_id}} when is_binary(parent_id) ->
        case Agents.get_agent(parent_id) do
          {:ok, %Agent{} = parent} -> parent
          _ -> ceo_or_nil(company_id)
        end

      _ ->
        ceo_or_nil(company_id)
    end
  end

  defp resolve_supervisor(%Issue{company_id: company_id}), do: ceo_or_nil(company_id)

  defp ceo_or_nil(nil), do: nil

  defp ceo_or_nil(company_id) when is_binary(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %Agent{} = ceo} -> ceo
      _ -> nil
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
