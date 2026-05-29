defmodule Cympho.ReviewNudges.StaleScanner do
  @moduledoc """
  Periodic sweep that keeps review nudges alive in the no-human-in-loop loop.

  `Cympho.ReviewNudges.queue_nudge/3` emits a single wake when a nudge is
  planned. If the target agent never picks it up (paused, max-capacity, run
  failed), the wake just sits there. This scanner watches the active nudge
  wakes and:

    1. **Reconciles first.** If the underlying blockers have cleared since
       the nudge was queued, `Cympho.ReviewNudges.reconcile_issue/1` consumes
       the wake and we move on.

    2. **Re-emits at T1.** If a nudge is older than `:stale_t1_seconds` and
       has been re-emitted fewer than `:max_re_emits` times, drop a fresh
       wake with reason `"review_nudge_re_emit"` so the heartbeat
       broadcast fires again. Wakes carry an `re_emit_count` in metadata.

    3. **Escalates at T2.** If a nudge is older than `:stale_t2_seconds` or
       has hit `:max_re_emits`, try a *different* agent in the same role
       (round-robin within role), then walk `Router.fallback_chain/1`. The
       issue's `assignee_id` + `assigned_role` are updated and a fresh wake
       fires for the new owner.

    4. **Last resort.** If every role in the chain is exhausted, the
       original wake is marked consumed and a high-priority Inbox entry is
       left for human attention.

  Driven from Cympho.Scheduler (Quantum) every few minutes — see
  config/config.exs.
  """

  import Ecto.Query, warn: false

  alias Cympho.Agents
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Orchestrator.Dispatcher.Router
  alias Cympho.Repo
  alias Cympho.ReviewNudges
  alias Cympho.Wakes
  alias Cympho.Wakes.AgentWake

  require Logger

  @default_t1_seconds 120
  @default_t2_seconds 600
  @default_max_re_emits 3

  @doc """
  Sweeps all active review-nudge wakes once. Safe to invoke from a Quantum
  job; returns a counters map for telemetry. Never raises.
  """
  def sweep(opts \\ []) do
    cfg = config(opts)
    cutoff_t1 = DateTime.utc_now() |> DateTime.add(-cfg.t1_seconds, :second)

    nudges =
      from(w in AgentWake,
        where:
          w.status in ["pending", "running"] and
            fragment("?->>'source' = ?", w.metadata, "review_nudge") and
            w.inserted_at < ^cutoff_t1
      )
      |> Repo.all()

    Enum.reduce(
      nudges,
      %{reconciled: 0, re_emitted: 0, escalated: 0, abandoned: 0, errors: 0},
      fn wake, acc ->
        try do
          case handle_nudge(wake, cfg) do
            {:reconciled, _} -> Map.update!(acc, :reconciled, &(&1 + 1))
            {:re_emitted, _} -> Map.update!(acc, :re_emitted, &(&1 + 1))
            {:escalated, _} -> Map.update!(acc, :escalated, &(&1 + 1))
            {:abandoned, _} -> Map.update!(acc, :abandoned, &(&1 + 1))
            {:skip, _} -> acc
          end
        rescue
          e ->
            Logger.warning(
              "[StaleScanner] error handling wake #{wake.id}: #{Exception.message(e)}"
            )

            Map.update!(acc, :errors, &(&1 + 1))
        end
      end
    )
  end

  defp handle_nudge(%AgentWake{} = wake, cfg) do
    with {:ok, issue} <- Issues.get_issue(wake.issue_id),
         :ok <- ensure_not_running(issue),
         {:ok, fresh} <- reconcile(issue, wake) do
      if fresh.status in ["pending", "running"] do
        age_seconds = DateTime.diff(DateTime.utc_now(), fresh.inserted_at, :second)
        re_emit_count = re_emit_count(fresh)

        cond do
          age_seconds >= cfg.t2_seconds or re_emit_count >= cfg.max_re_emits ->
            escalate(issue, fresh)

          true ->
            re_emit(issue, fresh, re_emit_count)
        end
      else
        {:reconciled, fresh}
      end
    else
      {:error, :issue_not_found} -> {:skip, :issue_gone}
      {:error, :running} -> {:skip, :assignee_running}
      other -> {:skip, other}
    end
  end

  # If the assignee is currently mid-run, the orchestrator owns the work;
  # piling on more wakes will not help and risks duplicate processing.
  defp ensure_not_running(issue) do
    case issue.assignee_id do
      nil ->
        :ok

      assignee_id ->
        case Agents.get_agent(assignee_id) do
          {:ok, %{status: :running}} -> {:error, :running}
          _ -> :ok
        end
    end
  end

  defp reconcile(issue, wake) do
    _ = ReviewNudges.reconcile_issue(issue)
    {:ok, Repo.get!(AgentWake, wake.id)}
  end

  defp re_emit_count(%AgentWake{metadata: metadata}) do
    case (metadata || %{})["re_emit_count"] do
      n when is_integer(n) -> n
      n when is_binary(n) -> String.to_integer(n)
      _ -> 0
    end
  end

  defp re_emit(issue, wake, current_count) do
    new_metadata =
      (wake.metadata || %{})
      |> Map.put("re_emit_count", current_count + 1)
      |> Map.put("re_emit_of", wake.id)

    {:ok, _new_wake} =
      Wakes.do_wake_agent(
        wake.agent_id,
        issue.id,
        "review_nudge_re_emit",
        "system",
        "stale_scanner",
        new_metadata
      )

    {:re_emitted, current_count + 1}
  end

  defp escalate(issue, wake) do
    primary_role = role_from_wake(wake) || Router.infer_role(issue)
    excluded = [wake.agent_id]

    case find_alternate(issue.company_id, primary_role, excluded) do
      {:ok, agent} ->
        {:ok, _updated} =
          Issues.update_issue(issue, %{
            assignee_id: agent.id,
            assigned_role: to_string(agent.role)
          })

        new_metadata =
          (wake.metadata || %{})
          |> Map.put("escalated_from", wake.id)
          |> Map.put("escalation_target_role", to_string(agent.role))
          |> Map.put("escalation_at", DateTime.utc_now() |> DateTime.to_iso8601())

        {:ok, _} =
          Wakes.do_wake_agent(
            agent.id,
            issue.id,
            "review_nudge_escalated",
            "system",
            "stale_scanner",
            new_metadata
          )

        _ = Wakes.consume_review_nudge(wake)
        {:escalated, agent.id}

      {:error, :exhausted} ->
        _ = Wakes.consume_review_nudge(wake)
        _ = leave_human_breadcrumb(issue, wake)
        {:abandoned, :exhausted}
    end
  end

  defp role_from_wake(%AgentWake{metadata: metadata}) do
    case (metadata || %{})["agent_role"] do
      role when is_binary(role) -> safe_to_role_atom(role)
      _ -> nil
    end
  end

  defp safe_to_role_atom(role) do
    Enum.find([:ceo, :cto, :engineer, :product_manager, :designer], &(to_string(&1) == role))
  end

  # Walk role + fallback chain, finding any eligible agent in the same
  # company that isn't already on the excluded list. Same-role first, then
  # the next link up.
  defp find_alternate(company_id, role, excluded) do
    chain = [role | Router.fallback_chain(role)]

    Enum.reduce_while(chain, {:error, :exhausted}, fn r, _acc ->
      eligible =
        company_id
        |> agents_for(r)
        |> Enum.reject(&(&1.id in excluded))

      case Router.select_agent(r, eligible) do
        {:ok, agent} -> {:halt, {:ok, agent}}
        _ -> {:cont, {:error, :exhausted}}
      end
    end)
  end

  defp agents_for(nil, _role), do: []

  defp agents_for(company_id, role) do
    Agents.list_eligible_agents(role, company_id)
  end

  defp leave_human_breadcrumb(issue, wake) do
    # The agent_id on the wake is the last-tried assignee; the inbox entry
    # carries enough metadata for a human operator to triage.
    case Inbox.ensure_inbox_entry(issue.id, wake.agent_id, refresh?: true) do
      {:ok, entry} ->
        Logger.warning(
          "[StaleScanner] review-nudge exhausted role chain for issue=#{issue.id} wake=#{wake.id} — left inbox entry #{entry.id}"
        )

        :ok

      other ->
        Logger.warning(
          "[StaleScanner] could not write breadcrumb inbox entry for wake #{wake.id}: #{inspect(other)}"
        )

        :ok
    end
  end

  defp config(opts) do
    base = Application.get_env(:cympho, :review_nudges, [])

    %{
      t1_seconds:
        Keyword.get(opts, :t1_seconds, Keyword.get(base, :stale_t1_seconds, @default_t1_seconds)),
      t2_seconds:
        Keyword.get(opts, :t2_seconds, Keyword.get(base, :stale_t2_seconds, @default_t2_seconds)),
      max_re_emits:
        Keyword.get(opts, :max_re_emits, Keyword.get(base, :max_re_emits, @default_max_re_emits))
    }
  end
end
