defmodule CymphoWeb.OperationsLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.AgentInstructionTuner
  alias Cympho.Agents
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
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_snapshot(socket)}
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

  defp assign_snapshot(socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    snapshot = RuntimeOperations.snapshot(company_id)

    socket
    |> assign(:page_title, "Operations")
    |> assign(:snapshot, snapshot)
    |> assign(:runtime_mode, snapshot.runtime_mode)
    |> assign(:services, snapshot.services)
    |> assign(:capacity, snapshot.capacity)
    |> assign(:host, snapshot.host)
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

  defp mode_badge_class(:autonomous),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp mode_badge_class(:review),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp mode_badge_class(:degraded),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp mode_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp status_badge_class(:running),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp status_badge_class(:boot_task),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp status_badge_class(:disabled),
    do: "border-border bg-surface text-text-tertiary"

  defp status_badge_class(:not_running),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp capacity_badge_class(:safe), do: "border-green-500/25 bg-green-500/10 text-green-400"
  defp capacity_badge_class(:watch), do: "border-yellow-500/25 bg-yellow-500/10 text-yellow-300"
  defp capacity_badge_class(:high), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp capacity_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp action_class(:ok), do: "border-emerald-500/20 bg-emerald-500/[0.08]"
  defp action_class(:attention), do: "border-amber-500/20 bg-amber-500/[0.08]"
  defp action_class(:danger), do: "border-red-500/20 bg-red-500/[0.08]"
  defp action_class(_), do: "border-border bg-surface"

  defp doctor_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp doctor_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp doctor_badge_class(:info),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp doctor_badge_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp doctor_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp doctor_card_class(:critical), do: "border-red-500/20 bg-red-500/[0.07]"
  defp doctor_card_class(:warning), do: "border-amber-500/20 bg-amber-500/[0.07]"
  defp doctor_card_class(:info), do: "border-blue-500/20 bg-blue-500/[0.07]"
  defp doctor_card_class(:ok), do: "border-emerald-500/20 bg-emerald-500/[0.07]"
  defp doctor_card_class(_), do: "border-border bg-surface"

  defp nudge_badge_class(:queued), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp nudge_badge_class(:running), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp nudge_badge_class(:stale), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp nudge_badge_class(:cleared), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  defp nudge_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp contract_badge_class(:missing),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp contract_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp contract_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp prompt_status_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp prompt_status_badge_class(:needs_tuning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp prompt_status_badge_class(:guardrail_risk),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp prompt_status_badge_class(:eval_gap),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp prompt_status_badge_class(:regressed),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp prompt_status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp prompt_card_class(:guardrail_risk), do: "border-red-500/25 bg-red-500/[0.06]"
  defp prompt_card_class(:eval_gap), do: "border-red-500/25 bg-red-500/[0.06]"
  defp prompt_card_class(:regressed), do: "border-blue-500/25 bg-blue-500/[0.06]"
  defp prompt_card_class(:needs_tuning), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp prompt_card_class(:ready), do: "border-emerald-500/20 bg-emerald-500/[0.05]"
  defp prompt_card_class(_), do: "border-border bg-surface"

  defp prompt_gap_class(:attention), do: "bg-red-500/10 text-red-200"
  defp prompt_gap_class(:weak), do: "bg-amber-500/10 text-amber-200"
  defp prompt_gap_class(_), do: "bg-canvas text-text-tertiary"

  defp prompt_patch_class(:primary), do: "bg-brand/15 text-brand"
  defp prompt_patch_class(:danger), do: "bg-red-500/10 text-red-200"
  defp prompt_patch_class(_), do: "bg-surface text-text-tertiary"

  defp anchor_path?(path) when is_binary(path), do: String.starts_with?(path, "#")
  defp anchor_path?(_), do: false

  defp health_status_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp health_status_badge_class(:degraded),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp health_status_badge_class(:unavailable),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp health_status_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp health_status_label(:healthy), do: "Healthy"
  defp health_status_label(:degraded), do: "Degraded"
  defp health_status_label(:unavailable), do: "Unavailable"
  defp health_status_label(status), do: role_label(status)

  defp role_label(:ceo), do: "CEO"
  defp role_label(:cto), do: "CTO"
  defp role_label("ceo"), do: "CEO"
  defp role_label("cto"), do: "CTO"
  defp role_label(:product_manager), do: "Product Manager"
  defp role_label("product_manager"), do: "Product Manager"

  defp role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp adapter_label(adapter) do
    adapter
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
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
