defmodule CymphoWeb.OperationsLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.AgentInstructionTuner
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.ReviewNudges
  alias Cympho.RuntimeOperations
  alias Cympho.Wakes

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_snapshot(socket)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign_snapshot(socket, parent_issue_id: Map.get(params, "parent_issue_id"))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_snapshot(socket)}
  end

  def handle_event("prioritize_dispatch", %{"issue-id" => issue_id}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         {:ok, _issue} <-
           Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
      {:noreply,
       socket
       |> assign_snapshot(include_launch_issue_id: issue_id)
       |> put_flash(:info, "Dispatch focus queued.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to queue dispatch focus.")}
    end
  end

  def handle_event("clear_dispatch_focus", %{"issue-id" => issue_id}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
         {:ok, _issue} <- Issues.clear_dispatch_focus(issue) do
      {:noreply,
       socket
       |> assign_snapshot(include_launch_issue_id: issue_id)
       |> put_flash(:info, "Dispatch focus cleared.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to clear dispatch focus.")}
    end
  end

  def handle_event("prioritize_delegated_work", _params, socket) do
    queueable_ids = delegated_work_queueable_ids(socket.assigns[:delegated_work])

    results = Enum.map(queueable_ids, &prioritize_delegated_work_item(socket, &1))
    queued = Enum.count(results, &(&1 == :ok))
    failed = Enum.count(results, &match?({:error, _reason}, &1))

    flash_kind = if failed > 0 and queued == 0, do: :error, else: :info

    {:noreply,
     socket
     |> assign_snapshot(include_launch_issue_id: List.first(queueable_ids))
     |> put_flash(flash_kind, delegated_work_queue_flash(queued, failed))}
  end

  def handle_event("recover_stale_runs", _params, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case recover_company_stale_runs(company_id) do
      {:ok,
       %{
         recovered: recovered,
         cancelled: cancelled,
         released: released,
         failed: 0,
         stale: stale,
         orphaned: orphaned,
         waiting: waiting,
         stale_checkouts: stale_checkouts
       }} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(
           :info,
           "Recovered #{recovered} stale/orphaned #{plural_noun(recovered, "run")}, cancelled #{cancelled} stale waiting #{plural_noun(cancelled, "run")}, and released #{released} stale checked-out #{plural_noun(released, "issue", "issues")}. Checked #{stale} stale, #{orphaned} orphaned, #{waiting} waiting, and #{stale_checkouts} checked-out candidates."
         )}

      {:ok, %{recovered: recovered, cancelled: cancelled, released: released, failed: failed}} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(
           :error,
           "Recovered #{recovered}, cancelled #{cancelled}, and released #{released}; #{failed} failed to update."
         )}

      {:error, :no_company} ->
        {:noreply, put_flash(socket, :error, "No company selected.")}
    end
  end

  def handle_event("preview_prompt_plan", %{"agent-id" => agent_id}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, agent} ->
        {:noreply, assign(socket, :prompt_plan_preview, prompt_plan_preview([agent], :agent))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found for this company.")}
    end
  end

  def handle_event("preview_prompt_plan", %{"scope" => "watchlist"}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    agents = prompt_watchlist_agents(company_id)

    {:noreply, assign(socket, :prompt_plan_preview, prompt_plan_preview(agents, :watchlist))}
  end

  def handle_event("close_prompt_preview", _params, socket) do
    {:noreply, assign(socket, :prompt_plan_preview, nil)}
  end

  def handle_event("apply_prompt_plan", %{"agent-id" => agent_id}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with {:ok, agent} <- Agents.get_company_agent(company_id, agent_id),
         {:ok, result} <- apply_prompt_tuning(agent, socket) do
      {:noreply,
       socket
       |> assign_snapshot()
       |> assign(:prompt_plan_preview, nil)
       |> put_flash(:info, prompt_tuning_flash(result))}
    else
      {:ok, %{status: :noop} = result} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> assign(:prompt_plan_preview, nil)
         |> put_flash(:info, prompt_tuning_flash(result))}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found for this company.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not apply prompt patches.")}
    end
  end

  def handle_event("apply_prompt_plan", %{"scope" => "watchlist"}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    results =
      company_id
      |> prompt_watchlist_agents()
      |> Enum.map(&apply_prompt_tuning(&1, socket))

    applied =
      Enum.count(results, fn
        {:ok, %{status: :applied}} -> true
        _ -> false
      end)

    skipped =
      Enum.count(results, fn
        {:ok, %{status: :noop}} -> true
        _ -> false
      end)

    failed = Enum.count(results, &match?({:error, _reason}, &1))

    message =
      cond do
        applied > 0 and failed == 0 ->
          "Applied prompt patches to #{applied} #{plural_noun(applied, "agent")}. #{skipped} already had the recommended patches."

        applied > 0 ->
          "Applied prompt patches to #{applied} #{plural_noun(applied, "agent")}; #{failed} failed."

        true ->
          "No prompt patches were applied."
      end

    flash_kind = if failed > 0, do: :error, else: :info

    {:noreply,
     socket
     |> assign_snapshot()
     |> assign(:prompt_plan_preview, nil)
     |> put_flash(flash_kind, message)}
  end

  def handle_event("clear_review_nudge", %{"id" => id}, socket) do
    case scoped_review_wake(socket, id) do
      {:ok, wake} ->
        case Wakes.consume_review_nudge(wake) do
          {:ok, wake} ->
            :ok = Inbox.notify_entry_updated(wake.issue_id, wake.agent_id)

            {:noreply,
             socket
             |> assign_snapshot()
             |> put_flash(:info, "Review nudge marked handled.")}

          {:error, :not_review_nudge} ->
            {:noreply, put_flash(socket, :error, "That wake is not a review nudge.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not clear review nudge.")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Review nudge not found.")}
    end
  end

  def handle_event("accept_owner_verification", %{"issue-id" => issue_id}, socket) do
    with {:ok, issue} <- scoped_issue(socket, issue_id),
         {:ok, _issue} <-
           Issues.accept_owner_verification(issue, actor: socket.assigns[:current_user]) do
      {:noreply,
       socket
       |> assign_snapshot()
       |> put_flash(:info, "CEO owner update accepted and issue closed.")}
    else
      {:error, :blocked_by_active_issues} ->
        {:noreply, put_flash(socket, :error, "Issue is blocked by active issues.")}

      {:error, :not_owner_verification} ->
        {:noreply, put_flash(socket, :error, "Issue is not waiting on owner verification.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found for this company.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to accept CEO owner update.")}
    end
  end

  def handle_event("request_owner_revision", %{"issue-id" => issue_id}, socket) do
    with {:ok, issue} <- scoped_issue(socket, issue_id),
         {:ok, issue} <-
           Issues.request_owner_verification_revision(issue, actor: socket.assigns[:current_user]) do
      {:noreply,
       socket
       |> assign_snapshot(include_launch_issue_id: issue.id)
       |> put_flash(:info, "CEO revision requested and focused relaunch queued.")}
    else
      {:error, :blocked_by_active_issues} ->
        {:noreply, put_flash(socket, :error, "Issue is blocked by active issues.")}

      {:error, :not_owner_verification} ->
        {:noreply, put_flash(socket, :error, "Issue is not waiting on owner verification.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found for this company.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to request CEO revision.")}
    end
  end

  def handle_event(
        "queue_contract_nudge",
        %{"issue-id" => issue_id, "contract" => contract_key},
        socket
      ) do
    with {:ok, issue} <- scoped_issue(socket, issue_id) do
      case ReviewNudges.execute_contract_gap(issue, contract_key,
             actor: socket.assigns[:current_user]
           ) do
        {:ok, %{already_queued?: true} = nudge} ->
          {:noreply,
           socket
           |> assign_snapshot()
           |> put_flash(:info, "Contract nudge is already queued for #{nudge.agent_name}.")}

        {:ok, nudge} ->
          :ok = Inbox.notify_entry_updated(nudge.issue_id, nudge.agent_id)

          {:noreply,
           socket
           |> assign_snapshot()
           |> put_flash(:info, "Contract nudge queued for #{nudge.agent_name}.")}

        {:error, :no_target_agent} ->
          {:noreply,
           put_flash(socket, :error, "No matching agent is available for that contract.")}

        {:error, :nudge_not_found} ->
          {:noreply, put_flash(socket, :error, "That prompt contract gap is no longer active.")}

        {:error, reason} ->
          {:noreply,
           put_flash(socket, :error, "Failed to queue contract nudge: #{inspect(reason)}")}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found for this company.")}
    end
  end

  defp scoped_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, issue_id)
      _ -> {:error, :not_found}
    end
  end

  defp scoped_review_wake(socket, wake_id) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with {:ok, wake} <- Wakes.get_agent_wake(wake_id),
         true <- wake_belongs_to_company?(wake, company_id) do
      {:ok, wake}
    else
      _ -> {:error, :not_found}
    end
  end

  defp wake_belongs_to_company?(%{issue: %{company_id: company_id}}, company_id)
       when is_binary(company_id),
       do: true

  defp wake_belongs_to_company?(%{agent: %{company_id: company_id}}, company_id)
       when is_binary(company_id),
       do: true

  defp wake_belongs_to_company?(_wake, _company_id), do: false

  defp delegated_work_queueable_ids(%{entries: entries}) when is_list(entries) do
    entries
    |> Enum.filter(&Map.get(&1, :queueable?))
    |> Enum.map(& &1.issue_id)
    |> Enum.reject(&is_nil/1)
  end

  defp delegated_work_queueable_ids(_delegated_work), do: []

  defp prioritize_delegated_work_item(socket, issue_id) do
    with {:ok, issue} <- scoped_issue(socket, issue_id),
         false <- Issues.dispatch_pinned?(issue),
         false <- Issues.is_blocked?(issue),
         {:ok, _issue} <-
           Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
      :ok
    else
      true -> {:skipped, :not_runnable}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unknown}
    end
  end

  defp delegated_work_queue_flash(0, 0),
    do: "No runnable delegated work needed dispatch focus."

  defp delegated_work_queue_flash(queued, 0) do
    "Queued #{queued} delegated #{plural_noun(queued, "work item")} for focused dispatch."
  end

  defp delegated_work_queue_flash(queued, failed) when queued > 0 do
    "Queued #{queued} delegated #{plural_noun(queued, "work item")}; #{failed} failed."
  end

  defp delegated_work_queue_flash(_queued, failed) do
    "Failed to queue #{failed} delegated #{plural_noun(failed, "work item")}."
  end

  defp assign_snapshot(socket, opts \\ []) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    parent_issue_id =
      Keyword.get(opts, :parent_issue_id, socket.assigns[:delegated_parent_issue_id])

    snapshot =
      RuntimeOperations.snapshot(
        company_id,
        opts
        |> Keyword.put(:parent_issue_id, parent_issue_id)
      )

    socket
    |> assign(:page_title, "Operations")
    |> assign(:delegated_parent_issue_id, parent_issue_id)
    |> assign(:snapshot, snapshot)
    |> assign(:runtime_mode, snapshot.runtime_mode)
    |> assign(:services, snapshot.services)
    |> assign(:capacity, snapshot.capacity)
    |> assign(:host, snapshot.host)
    |> assign(:runtime_enablement, snapshot.runtime_enablement)
    |> assign(:launch_preview, snapshot.launch_preview)
    |> assign(:ceo_outcomes, snapshot.ceo_outcomes)
    |> assign(:delegated_work, snapshot.delegated_work)
    |> assign(:owner_signoffs, snapshot.owner_signoffs)
    |> assign(:doctor, snapshot.doctor)
    |> assign(:health, snapshot.health)
    |> assign(:pressure_agents, snapshot.pressure_agents)
    |> assign(:prompt_radar, snapshot.prompt_radar)
    |> assign(:review_nudges, snapshot.review_nudges)
    |> assign(:contract_failures, snapshot.contract_failures)
    |> assign(:recent_failures, snapshot.recent_failures)
    |> assign(:next_actions, snapshot.next_actions)
    |> assign_new(:prompt_plan_preview, fn -> nil end)
  end

  defp prompt_watchlist_agents(nil), do: []

  defp prompt_watchlist_agents(company_id) do
    company_id
    |> Agents.list_agents_by_company()
    |> Enum.reject(&(&1.governance_status == "terminated" or &1.status == :terminated))
    |> Enum.filter(fn agent ->
      plan = AgentInstructionTuner.plan(agent)

      plan.changed and plan.projected_score > plan.current_score
    end)
  end

  defp apply_prompt_tuning(agent, socket) do
    case AgentInstructionTuner.apply(agent) do
      {:ok, instructions, plan} ->
        with {:ok, updated_agent} <- Agents.update_agent(agent, %{instructions: instructions}),
             {:ok, revision} <-
               Agents.create_config_revision(updated_agent, %{
                 source: "prompt_tuning",
                 created_by_user_id: current_user_id(socket)
               }) do
          {:ok,
           %{
             status: :applied,
             agent_name: agent.name,
             patch_count: plan.patch_count,
             from_score: plan.current_score,
             to_score: plan.projected_score,
             revision: revision.version
           }}
        end

      {:noop, plan} ->
        {:ok,
         %{
           status: :noop,
           agent_name: agent.name,
           patch_count: plan.patch_count,
           from_score: plan.current_score,
           to_score: plan.projected_score
         }}
    end
  end

  defp prompt_plan_preview(agents, scope) do
    rows =
      agents
      |> Enum.map(fn agent -> {agent, AgentInstructionTuner.plan(agent)} end)
      |> Enum.filter(fn {_agent, plan} ->
        plan.changed and plan.projected_score > plan.current_score
      end)
      |> Enum.map(fn {agent, plan} ->
        %{
          id: agent.id,
          name: agent.name,
          role: agent.role,
          adapter: agent.adapter,
          current_score: plan.current_score,
          current_status_label: plan.current_status_label,
          projected_score: plan.projected_score,
          projected_status_label: plan.projected_status_label,
          patch_count: plan.patch_count,
          patches: plan.patches
        }
      end)

    %{
      scope: scope,
      empty?: rows == [],
      agent_count: length(rows),
      patch_count: Enum.reduce(rows, 0, &(&1.patch_count + &2)),
      agents: rows
    }
  end

  defp prompt_tuning_flash(%{status: :applied} = result) do
    "Applied #{result.patch_count} prompt #{plural_noun(result.patch_count, "patch", "patches")} to #{result.agent_name}. Score #{result.from_score}/100 → #{result.to_score}/100. Revision v#{result.revision} recorded."
  end

  defp prompt_tuning_flash(%{status: :noop, agent_name: name}) do
    "#{name} already has the recommended prompt patches."
  end

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp recover_company_stale_runs(nil), do: {:error, :no_company}

  defp recover_company_stale_runs(company_id) do
    stale_runs = HeartbeatEngine.find_stale_runs_for_company(company_id)
    orphaned_runs = HeartbeatEngine.find_orphaned_runs_for_company(company_id)
    waiting_runs = HeartbeatEngine.find_stale_waiting_runs_for_company(company_id)

    runs =
      (stale_runs ++ orphaned_runs)
      |> Map.new(&{&1.id, &1})
      |> Map.values()

    recovery_results = Enum.map(runs, &HeartbeatEngine.recover_stale_run/1)
    cancel_results = Enum.map(waiting_runs, &HeartbeatEngine.cancel_run/1)
    {:ok, checkout_results} = RuntimeOperations.recover_stale_checked_out_issues(company_id)
    results = recovery_results ++ cancel_results

    recovered = Enum.count(recovery_results, &match?({:ok, _}, &1))
    cancelled = Enum.count(cancel_results, &match?({:ok, _}, &1))
    released = checkout_results.released
    failed = Enum.count(results, &match?({:error, _}, &1)) + checkout_results.failed

    {:ok,
     %{
       recovered: recovered,
       cancelled: cancelled,
       released: released,
       failed: failed,
       stale: length(stale_runs),
       orphaned: length(orphaned_runs),
       waiting: length(waiting_runs),
       stale_checkouts: checkout_results.checked
     }}
  end

  defp status_badge_class(:running),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp status_badge_class(:boot_task),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp status_badge_class(:disabled),
    do: "border-border bg-surface text-text-tertiary"

  defp status_badge_class(:not_running),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp service_purpose_badge_class(:core),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp service_purpose_badge_class(:automation),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp service_purpose_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp capacity_badge_class(:safe), do: "border-green-500/25 bg-green-500/10 text-green-400"
  defp capacity_badge_class(:watch), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-300"
  defp capacity_badge_class(:high), do: "border-brand/25 bg-brand/10 text-brand"
  defp capacity_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp action_class(:ok), do: "border-border bg-surface"
  defp action_class(:attention), do: "border-border bg-surface"
  defp action_class(:danger), do: "border-border bg-surface"
  defp action_class(_), do: "border-border bg-surface"

  defp doctor_badge_class(:critical),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp doctor_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp doctor_badge_class(:info),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp doctor_badge_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp doctor_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp doctor_card_class(:critical), do: "border-border border-l-2 border-l-brand/70 bg-surface"

  defp doctor_card_class(:warning),
    do: "border-border border-l-2 border-l-amber-500/70 bg-surface"

  defp doctor_card_class(:info), do: "border-border border-l-2 border-l-blue-500/70 bg-surface"
  defp doctor_card_class(:ok), do: "border-border border-l-2 border-l-emerald-500/70 bg-surface"
  defp doctor_card_class(_), do: "border-border bg-surface"

  defp action_left_bar(:ok), do: "border-l-emerald-500/70"
  defp action_left_bar(:attention), do: "border-l-amber-500/70"
  defp action_left_bar(:danger), do: "border-l-brand/70"
  defp action_left_bar(_), do: "border-l-brand/70"

  defp mode_text_class(:autonomous), do: "text-green-300"
  defp mode_text_class(:review), do: "text-sky-300"
  defp mode_text_class(:degraded), do: "text-amber-300"
  defp mode_text_class(_), do: "text-text-tertiary"

  defp mode_dot_class(:autonomous), do: "bg-green-400"
  defp mode_dot_class(:review), do: "bg-sky-400"
  defp mode_dot_class(:degraded), do: "bg-amber-400"
  defp mode_dot_class(_), do: "bg-gray-500"

  defp mode_pulse_color(:autonomous), do: "rgba(93, 184, 114, 0.55)"
  defp mode_pulse_color(:review), do: "rgba(93, 184, 166, 0.55)"
  defp mode_pulse_color(:degraded), do: "rgba(232, 165, 90, 0.55)"
  defp mode_pulse_color(_), do: "rgba(176, 169, 156, 0.45)"

  defp enablement_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp enablement_badge_class(:running), do: "border-green-500/25 bg-green-500/10 text-green-400"
  defp enablement_badge_class(:blocked), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp enablement_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp launch_priority_class(:critical), do: "border-brand/25 bg-brand/10 text-brand"
  defp launch_priority_class(:high), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp launch_priority_class(:medium), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp launch_priority_class(:low), do: "border-border bg-surface text-text-tertiary"
  defp launch_priority_class(_), do: "border-border bg-surface text-text-tertiary"

  defp launch_order_class(:first_poll),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp launch_order_class(:operator_focus),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp launch_order_class(:later), do: "border-border bg-panel text-text-tertiary"
  defp launch_order_class(_), do: "border-border bg-panel text-text-tertiary"

  defp launch_preview_summary(%{status: :review}, launch_preview) do
    "Review mode is on. This preview shows queue order and preflight checks before you start runtime; focused commands still run one issue first."
    |> maybe_append_launch_limit(launch_preview)
  end

  defp launch_preview_summary(_runtime_mode, launch_preview) do
    "Dispatch can start up to #{launch_preview.max_concurrent} #{plural_noun(launch_preview.max_concurrent, "issue")} per poll. This preview mirrors the dispatcher priority order before any agent is started."
  end

  defp maybe_append_launch_limit(summary, %{max_concurrent: max_concurrent}) do
    "#{summary} Runtime will take up to #{max_concurrent} #{plural_noun(max_concurrent, "issue")} per poll after launch."
  end

  defp launch_preview_footer(%{
         included_followup_candidate?: true,
         primary_shown: primary_shown,
         total_candidates: total_candidates
       })
       when total_candidates > primary_shown do
    "Showing first #{primary_shown} candidates plus the issue you just updated, of #{total_candidates} candidates."
  end

  defp launch_preview_footer(%{shown: shown, total_candidates: total_candidates})
       when total_candidates > shown do
    "Showing first #{shown} of #{total_candidates} candidates."
  end

  defp launch_preview_footer(_launch_preview), do: nil

  defp preflight_action_target_path(action) when is_map(action) do
    Map.get(action, :target_path) || Map.get(action, "target_path")
  end

  defp preflight_action_target_path(_action), do: nil

  defp preflight_action_target_label(action) when is_map(action) do
    Map.get(action, :target_label) || Map.get(action, "target_label") || "Fix"
  end

  defp preflight_action_target_label(_action), do: "Fix"

  defp preflight_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp preflight_badge_class(:review_mode),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp preflight_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp preflight_badge_class(:blocked), do: "border-brand/25 bg-brand/10 text-brand"
  defp preflight_badge_class(_), do: "border-border bg-panel text-text-tertiary"

  defp readiness_dot_class(:ok), do: "h-1.5 w-1.5 rounded-full bg-emerald-400"
  defp readiness_dot_class(:info), do: "h-1.5 w-1.5 rounded-full bg-sky-400"
  defp readiness_dot_class(:attention), do: "h-1.5 w-1.5 rounded-full bg-amber-400"
  defp readiness_dot_class(:blocked), do: "h-1.5 w-1.5 rounded-full bg-brand"
  defp readiness_dot_class(_), do: "h-1.5 w-1.5 rounded-full bg-text-quaternary"

  defp nudge_badge_class(:queued), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp nudge_badge_class(:running), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp nudge_badge_class(:stale), do: "border-brand/25 bg-brand/10 text-brand"
  defp nudge_badge_class(:cleared), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  defp nudge_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp contract_badge_class(:missing),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp contract_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp contract_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp prompt_status_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp prompt_status_badge_class(:needs_tuning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp prompt_status_badge_class(:guardrail_risk),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp prompt_status_badge_class(:eval_gap),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp prompt_status_badge_class(:regressed),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp prompt_status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp prompt_card_class(:guardrail_risk),
    do: "border-border border-l-2 border-l-brand/70 bg-surface"

  defp prompt_card_class(:eval_gap), do: "border-border border-l-2 border-l-brand/70 bg-surface"

  defp prompt_card_class(:regressed),
    do: "border-border border-l-2 border-l-blue-500/70 bg-surface"

  defp prompt_card_class(:needs_tuning),
    do: "border-border border-l-2 border-l-amber-500/70 bg-surface"

  defp prompt_card_class(:ready),
    do: "border-border border-l-2 border-l-emerald-500/70 bg-surface"

  defp prompt_card_class(_), do: "border-border bg-surface"

  defp prompt_gap_class(:attention), do: "bg-brand/10 text-brand"
  defp prompt_gap_class(:weak), do: "bg-amber-500/10 text-amber-200"
  defp prompt_gap_class(_), do: "bg-canvas text-text-tertiary"

  defp prompt_patch_class(:primary), do: "bg-brand/15 text-brand"
  defp prompt_patch_class(:danger), do: "bg-brand/10 text-brand"
  defp prompt_patch_class(_), do: "bg-surface text-text-tertiary"

  defp anchor_path?(path) when is_binary(path), do: String.starts_with?(path, "#")
  defp anchor_path?(_), do: false

  defp health_status_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp health_status_badge_class(:degraded),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp health_status_badge_class(:unavailable),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp health_status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unavailable), do: "Unavailable"
  defp health_status_label(status), do: role_label(status)

  defp ceo_outcome_badge_class(:owner_update),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp ceo_outcome_badge_class(:owner_accepted),
    do: "border-teal-500/25 bg-teal-500/10 text-teal-300"

  defp ceo_outcome_badge_class(:owner_revision),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp ceo_outcome_badge_class(:handoff),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp ceo_outcome_badge_class(:decomposition),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp ceo_outcome_badge_class(:governance),
    do: "border-violet-500/25 bg-violet-500/10 text-violet-300"

  defp ceo_outcome_badge_class(:blocked),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp ceo_outcome_badge_class(:running),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp ceo_outcome_badge_class(:silent),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp ceo_outcome_badge_class(:failed),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp ceo_outcome_badge_class(:comment),
    do: "border-border bg-surface text-text-tertiary"

  defp ceo_outcome_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp role_label(role), do: Agent.role_label(role)

  defp adapter_label(adapter) do
    if adapter in [:openai_chat, "openai_chat"] do
      "OpenAI Chat"
    else
      adapter
      |> to_string()
      |> String.replace("_", " ")
      |> String.split()
      |> Enum.map_join(" ", &String.capitalize/1)
    end
  end

  defp short_id(nil), do: "unknown"
  defp short_id(id), do: String.slice(to_string(id), 0, 8)

  defp format_relative(nil), do: "unknown"

  defp format_relative(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86_400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp format_relative(_), do: "unknown"

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 3600 do
    "#{div(seconds, 3600)}h"
  end

  defp format_duration(seconds) when is_integer(seconds) and seconds >= 60 do
    "#{div(seconds, 60)}m"
  end

  defp format_duration(_), do: "<1m"

  defp format_memory(bytes) when is_integer(bytes) and bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 1)} GB"
  end

  defp format_memory(bytes) when is_integer(bytes) do
    "#{Float.round(bytes / 1_048_576, 1)} MB"
  end

  defp format_memory(_), do: "unknown"

  defp plural_noun(1, singular, _plural), do: singular
  defp plural_noun(_count, _singular, plural), do: plural

  defp plural_noun(count, singular), do: plural_noun(count, singular, singular <> "s")
end
