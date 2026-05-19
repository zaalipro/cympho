defmodule Cympho.Orchestrator.BacklogPlanner do
  @moduledoc """
  Per-company "what's next?" loop. The dispatcher only acts on issues that
  already exist; the planner watches for the gap above that — when a company
  has live mission goals but nothing in flight — and wakes the CEO so the
  fire-and-forget loop never goes silent.

  The planner runs a single timer (default every 5 minutes) and on each tick:

    1. Lists active companies.
    2. For each company, counts active issues (`:todo`, `:in_progress`,
       `:in_review`, `:blocked`) and active mission goals.
    3. If active issues == 0 and active missions > 0:
         a. Resolves the company CEO via `Agents.get_company_ceo/1`.
         b. Lazily creates (or re-uses) a synthetic "Mission Planning" issue
            for that CEO via `ensure_planning_issue/2`.
         c. Enqueues a `mission_idle` wake against the planning issue so the
            CEO's heartbeat picks it up on next broadcast.

  The planner intentionally does not wake more than once per company per
  `@cooldown_ms` window — the wake queue will coalesce duplicates anyway,
  but this keeps log noise down and avoids re-creating planning issues if
  someone deletes one out from under us.

  Disabled in tests via the `:start_backlog_planner?` app env flag (mirrors
  the watchdog/executor pattern in `Cympho.Application`).
  """

  use GenServer
  import Ecto.Query, warn: false

  alias Cympho.Repo
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.Goals.Goal
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Wakes

  require Logger

  @default_check_interval :timer.minutes(5)
  @default_cooldown_ms :timer.minutes(15)

  # Statuses that count as "in flight" — if any issue in the company is in
  # one of these we consider the company busy and skip planning.
  @active_issue_statuses [:todo, :in_progress, :in_review, :blocked]

  @planning_issue_origin "backlog_planner"

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Triggers an immediate planner sweep, bypassing the timer."
  @spec sweep_now() :: :ok | {:error, :not_started}
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
  Synchronously runs one planning sweep across all companies and returns a
  counters map. Useful from tests and from scheduled jobs.
  """
  @spec sweep_companies(keyword()) :: %{
          checked: non_neg_integer(),
          waked: non_neg_integer(),
          skipped_busy: non_neg_integer(),
          skipped_no_mission: non_neg_integer(),
          skipped_no_ceo: non_neg_integer(),
          errors: non_neg_integer()
        }
  def sweep_companies(opts \\ []) do
    companies = list_active_companies(opts)

    Enum.reduce(
      companies,
      %{
        checked: 0,
        waked: 0,
        skipped_busy: 0,
        skipped_no_mission: 0,
        skipped_no_ceo: 0,
        errors: 0
      },
      fn company, acc ->
        try do
          merge_counter(acc, plan_one_company(company.id, opts))
        rescue
          e ->
            Logger.warning(
              "[BacklogPlanner] error planning company #{company.id}: #{Exception.message(e)}"
            )

            Map.update!(acc, :errors, &(&1 + 1))
        end
      end
    )
  end

  @doc """
  Plans for a single company. Returns the per-company counter delta for
  `sweep_companies/1` to merge.
  """
  @spec plan_one_company(binary(), keyword()) :: map()
  def plan_one_company(company_id, opts \\ []) when is_binary(company_id) do
    base = %{checked: 1}

    cond do
      active_issue_count(company_id) > 0 ->
        Map.put(base, :skipped_busy, 1)

      active_mission_count(company_id) == 0 ->
        Map.put(base, :skipped_no_mission, 1)

      true ->
        case Agents.get_company_ceo(company_id) do
          {:ok, ceo} ->
            do_wake_ceo(ceo, company_id, opts)
            Map.put(base, :waked, 1)

          _ ->
            Map.put(base, :skipped_no_ceo, 1)
        end
    end
  end

  @doc """
  Lazily creates (or re-uses) a synthetic "Mission Planning" issue assigned
  to the company CEO. Used as the operating issue for `mission_idle` wakes
  so the orchestrator (which always runs in the context of an issue) has
  somewhere to land.

  Returns `{:ok, issue}` or `{:error, reason}`.
  """
  @spec ensure_planning_issue(binary(), Cympho.Agents.Agent.t() | nil) ::
          {:ok, Issue.t()} | {:error, term()}
  def ensure_planning_issue(company_id, ceo_agent \\ nil) when is_binary(company_id) do
    ceo = resolve_ceo_arg(ceo_agent, company_id)

    case fetch_planning_issue(company_id) do
      %Issue{} = existing ->
        # Force the planning issue back to a clean :todo with the CEO
        # assigned. Without this it would stay in :in_progress after a CEO
        # run and the dispatcher would never re-pick it up — and we'd skip
        # planning forever because the planner counts :in_progress as
        # "busy" (with the planning-issue exception).
        reset_planning_issue(existing, ceo)

      nil ->
        # Pick the company's first active project as the planning issue's
        # home. `Issues.create_issue` calls `maybe_generate_identifier`
        # which requires a non-nil project_id to fetch the prefix. Fall
        # back to nil if a company has no projects (rare but possible).
        project_id = first_active_project_id(company_id)

        attrs = %{
          title: "Mission Planning",
          description:
            "Synthetic planning issue. Cympho re-uses this issue whenever the company is idle but has live mission goals — the CEO operates on it to seed the next initiatives. Do NOT close this issue manually; the planner will clear and re-use it.",
          status: :todo,
          priority: "high",
          company_id: company_id,
          project_id: project_id,
          assignee_id: ceo && ceo.id,
          assigned_role: "ceo",
          origin_type: @planning_issue_origin,
          origin_id: company_id,
          actor_type: "system",
          actor_id: nil
        }

        Issues.create_issue(attrs)
    end
  end

  defp first_active_project_id(company_id) do
    Repo.one(
      from p in Cympho.Projects.Project,
        where: p.company_id == ^company_id and p.status == :active,
        order_by: [asc: p.inserted_at],
        limit: 1,
        select: p.id
    )
  end

  # Accepts either a raw %Agent{}, nil, or a {:ok, agent} | {:error, _} tuple
  # from `Agents.get_company_ceo/1`. Returns a %Agent{} or nil.
  defp resolve_ceo_arg(%Cympho.Agents.Agent{} = agent, _company_id), do: agent

  defp resolve_ceo_arg(nil, company_id) when is_binary(company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, %Cympho.Agents.Agent{} = ceo} -> ceo
      _ -> nil
    end
  end

  defp resolve_ceo_arg(_, _), do: nil

  defp reset_planning_issue(%Issue{} = issue, ceo) do
    ceo_id = ceo && ceo.id

    cond do
      issue.status == :todo and issue.assignee_id == ceo_id ->
        {:ok, issue}

      true ->
        # `force_release_issue` clears assignee + flips status. Then we
        # re-attach the CEO as assignee in a follow-up update so the
        # dispatcher's normal `checkout_issue` path picks the issue up
        # without contention with another agent.
        with {:ok, released} <- Issues.force_release_issue(issue, :todo),
             {:ok, attached} <-
               Issues.update_issue(released, %{
                 assignee_id: ceo_id,
                 assigned_role: "ceo"
               }) do
          {:ok, attached}
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

    if counters.waked > 0 do
      Logger.info("[BacklogPlanner] sweep counters=#{inspect(counters)}")
    end

    schedule_sweep(state.opts)
    {:noreply, %{state | last_swept_at: DateTime.utc_now()}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  ## Internal

  defp schedule_sweep(opts) do
    interval = Keyword.get(opts, :check_interval_ms, @default_check_interval)
    Process.send_after(self(), :sweep, interval)
  end

  defp list_active_companies(opts) do
    case Keyword.get(opts, :company_ids) do
      ids when is_list(ids) ->
        Repo.all(from c in Company, where: c.id in ^ids)

      _ ->
        Companies.list_companies()
        |> Enum.filter(&Companies.active?/1)
    end
  end

  defp active_issue_count(company_id) do
    Repo.one(
      from i in Issue,
        where: i.company_id == ^company_id and i.status in ^@active_issue_statuses,
        # Exclude planning issues — they're synthetic and otherwise the
        # planner would consider every company "busy" forever after the
        # first wake.
        where: i.origin_type != ^@planning_issue_origin or is_nil(i.origin_type),
        select: count(i.id)
    ) || 0
  end

  defp active_mission_count(company_id) do
    Repo.one(
      from g in Goal,
        where:
          g.company_id == ^company_id and
            g.goal_type == ^:mission and
            g.status == "active",
        select: count(g.id)
    ) || 0
  end

  defp fetch_planning_issue(company_id) do
    Repo.one(
      from i in Issue,
        where:
          i.company_id == ^company_id and
            i.origin_type == ^@planning_issue_origin and
            i.status != :cancelled,
        order_by: [desc: i.inserted_at],
        limit: 1
    )
  end

  defp do_wake_ceo(ceo, company_id, opts) do
    cooldown_ms = Keyword.get(opts, :cooldown_ms, @default_cooldown_ms)

    if recently_waked?(ceo.id, cooldown_ms) do
      :skip
    else
      case ensure_planning_issue(company_id, ceo) do
        {:ok, planning_issue} ->
          metadata = %{
            "company_id" => company_id,
            "active_missions" => active_mission_count(company_id),
            "swept_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          case Wakes.wake_for_mission_idle(ceo.id, planning_issue.id, metadata) do
            {:ok, _wake} ->
              :ok

            {:error, reason} ->
              Logger.warning(
                "[BacklogPlanner] wake_for_mission_idle failed for company #{company_id}: #{inspect(reason)}"
              )

              :error
          end

        {:error, reason} ->
          Logger.warning(
            "[BacklogPlanner] ensure_planning_issue failed for company #{company_id}: #{inspect(reason)}"
          )

          :error
      end
    end
  end

  defp recently_waked?(ceo_agent_id, cooldown_ms) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-div(cooldown_ms, 1000), :second)

    Repo.exists?(
      from w in Cympho.Wakes.AgentWake,
        where:
          w.agent_id == ^ceo_agent_id and
            w.reason == "mission_idle" and
            w.inserted_at > ^cutoff
    )
  end

  defp merge_counter(acc, delta) do
    Enum.reduce(delta, acc, fn {k, v}, acc -> Map.update(acc, k, v, &(&1 + v)) end)
  end
end
