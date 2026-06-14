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

  def handle_event("create_ceo_flow_smoke_issue", _params, socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        create_ceo_flow_smoke_issue(socket, company_id)

      _ ->
        {:noreply, put_flash(socket, :error, "No company selected.")}
    end
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

  def handle_event("clear_all_dispatch_focus", _params, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case Issues.clear_company_dispatch_focus(company_id) do
      {:ok, %{cleared: cleared}} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(:info, clear_all_dispatch_focus_flash(cleared))}

      _ ->
        {:noreply, put_flash(socket, :error, "Failed to clear focused dispatch queue.")}
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

  def handle_event("clear_stale_comment_wakes", _params, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case Wakes.consume_stale_comment_wakes(company_id,
           older_than_minutes: RuntimeOperations.stale_comment_wake_minutes()
         ) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(:info, "No stale comment wakes needed clearing.")}

      {:ok, cleared} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(
           :info,
           "Cleared #{cleared} stale comment #{plural_noun(cleared, "wake")}."
         )}
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

  def handle_event("close_prompt_receipt", _params, socket) do
    {:noreply, assign(socket, :prompt_tuning_receipt, nil)}
  end

  def handle_event("apply_prompt_plan", %{"agent-id" => agent_id}, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with {:ok, agent} <- Agents.get_company_agent(company_id, agent_id),
         {:ok, result} <- apply_prompt_tuning(agent, socket) do
      {:noreply,
       socket
       |> assign_snapshot()
       |> assign(:prompt_plan_preview, nil)
       |> assign(:prompt_tuning_receipt, prompt_tuning_receipt([result]))
       |> put_flash(:info, prompt_tuning_flash(result))}
    else
      {:ok, %{status: :noop} = result} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> assign(:prompt_plan_preview, nil)
         |> assign(:prompt_tuning_receipt, nil)
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

    applied_results =
      Enum.flat_map(results, fn
        {:ok, %{status: :applied} = result} -> [result]
        _ -> []
      end)

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
     |> assign(:prompt_tuning_receipt, prompt_tuning_receipt(applied_results))
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

  defp clear_all_dispatch_focus_flash(0), do: "No focused dispatch queue items needed clearing."

  defp clear_all_dispatch_focus_flash(cleared) do
    "Cleared #{cleared} focused dispatch #{plural_noun(cleared, "item")}."
  end

  defp create_ceo_flow_smoke_issue(socket, company_id) do
    with {:ok, ceo} <- Agents.get_company_ceo(company_id),
         {:ok, issue} <- Issues.create_issue(ceo_flow_smoke_issue_attrs(socket, ceo)) do
      case Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
        {:ok, focused_issue} ->
          {:noreply,
           socket
           |> assign_snapshot(include_launch_issue_id: focused_issue.id)
           |> put_flash(
             :info,
             "CEO to CTO flow smoke test created and queued for focused dispatch."
           )}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign_snapshot(include_launch_issue_id: issue.id)
           |> put_flash(
             :error,
             "CEO to CTO flow smoke test created, but dispatch focus could not be queued."
           )}
      end
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Create a CEO agent before running the smoke test.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create CEO flow smoke test.")}
    end
  end

  defp ceo_flow_smoke_issue_attrs(socket, ceo) do
    %{
      title: "CEO to CTO flow smoke test #{smoke_issue_suffix()}",
      description: ceo_flow_smoke_description(),
      status: :todo,
      priority: :high,
      assigned_role: "ceo",
      assignee_id: ceo.id,
      company_id: ceo.company_id,
      created_by_user_id: current_user_id(socket)
    }
  end

  defp smoke_issue_suffix do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%d-%H%M%S")
  end

  defp ceo_flow_smoke_description do
    """
    Goal:
    Verify the owner-to-CEO-to-CTO autonomous delegation flow end to end.

    Context:
    This controlled issue was created from Operations to test whether the CEO can accept an owner request, route technical planning through the CTO, and leave a visible parent outcome that an owner can audit.

    Constraints:
    Do not modify production code or external systems in the CEO turn. Keep this to planning, delegation, handoff, or governance output. If execution is needed, the CEO should delegate it instead of claiming implementation.

    Definition of done:
    Create or delegate exactly one CTO-owned child issue for technical planning with acceptance criteria, evidence required, verification required, definition of done, dependency order, estimated minutes, and review owner. Mark this parent blocked as waiting on the delegated CTO evidence and leave a tagged parent comment with the restart packet.

    CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`):
    Prefer a `[handoff]` outcome: name the CTO child, why it advances this smoke test, the exact routing target, expected evidence, verification gate, remaining risk, next decision, and restart packet. Use `[blocked]` only if the CEO cannot create or route the CTO child.

    Evidence to inspect after the run:
    Operations CEO flow verification, delegated work queue, CEO outcome monitor, the created CTO child issue, and the parent blocker/restart packet.
    """
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
    |> assign(:launch_plan, snapshot.launch_plan)
    |> assign(:launch_preview, snapshot.launch_preview)
    |> assign(:ceo_outcomes, snapshot.ceo_outcomes)
    |> assign(:ceo_flow, snapshot.ceo_flow)
    |> assign(:delegated_work, snapshot.delegated_work)
    |> assign(:owner_signoffs, snapshot.owner_signoffs)
    |> assign(:doctor, snapshot.doctor)
    |> assign(:org_health, snapshot.org_health)
    |> assign(:health, snapshot.health)
    |> assign(:pressure_agents, snapshot.pressure_agents)
    |> assign(:prompt_radar, snapshot.prompt_radar)
    |> assign(:review_nudges, snapshot.review_nudges)
    |> assign(:wake_queue, snapshot.wake_queue)
    |> assign(:contract_failures, snapshot.contract_failures)
    |> assign(:recent_failures, snapshot.recent_failures)
    |> assign(:next_actions, snapshot.next_actions)
    |> assign_new(:prompt_plan_preview, fn -> nil end)
    |> assign_new(:prompt_tuning_receipt, fn -> nil end)
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
        release = prompt_tuning_release(agent, plan)

        with {:ok, updated_agent} <- Agents.update_agent(agent, %{instructions: instructions}),
             {:ok, revision} <-
               Agents.create_config_revision(updated_agent, %{
                 source: "prompt_tuning",
                 created_by_user_id: current_user_id(socket),
                 studio_audits_extra: %{"tuning_release" => release}
               }) do
          {:ok,
           %{
             status: :applied,
             agent_name: agent.name,
             patch_count: plan.patch_count,
             patch_titles: Enum.map(plan.patches, & &1.title),
             from_score: plan.current_score,
             to_score: plan.projected_score,
             revision: revision.version,
             expected_effect: release["expected_effect"],
             validation_checks: release["validation_checks"],
             rollback: release["rollback"]
           }}
        end

      {:noop, plan} ->
        {:ok,
         %{
           status: :noop,
           agent_name: agent.name,
           patch_count: plan.patch_count,
           patch_titles: Enum.map(plan.patches, & &1.title),
           from_score: plan.current_score,
           to_score: plan.projected_score,
           validation_checks: plan.validation_checks
         }}
    end
  end

  defp prompt_tuning_release(agent, plan) do
    patch_titles = Enum.map(plan.patches, & &1.title)

    %{
      "kind" => "prompt_tuning_release",
      "agent_name" => agent.name,
      "role" => role_label(agent.role),
      "adapter" => adapter_label(agent.adapter),
      "patch_count" => plan.patch_count,
      "patches" =>
        Enum.map(plan.patches, fn patch ->
          %{
            "id" => patch.id,
            "title" => patch.title,
            "reason" => patch.reason
          }
        end),
      "score" => %{
        "from" => plan.current_score,
        "to" => plan.projected_score,
        "from_status" => plan.current_status_label,
        "to_status" => plan.projected_status_label
      },
      "expected_effect" => prompt_tuning_expected_effect(plan.patches),
      "validation_checks" => plan.validation_checks,
      "rollback" =>
        "Use the agent Instruction Studio revision history to restore the previous prompt if the next run regresses."
    }
    |> Map.put("summary", prompt_tuning_release_summary(agent.name, patch_titles, plan))
  end

  defp prompt_tuning_release_summary(agent_name, patch_titles, plan) do
    "#{agent_name}: #{Enum.join(patch_titles, ", ")} raised prompt guardrails from #{plan.current_score}/100 to #{plan.projected_score}/100."
  end

  defp prompt_tuning_expected_effect(patches) do
    effects =
      patches
      |> Enum.map(&prompt_tuning_effect(&1.id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case effects do
      [] -> "No behavior change expected."
      [effect] -> effect
      effects -> Enum.join(effects, " ")
    end
  end

  defp prompt_tuning_effect("owner-memory"),
    do: "Runs should leave clearer owner-readable issue memory."

  defp prompt_tuning_effect("operating-loop"),
    do: "Runs should follow a more consistent orient, decide, act, verify, report loop."

  defp prompt_tuning_effect("ceo-delegation"),
    do: "CEO turns should produce clearer owner updates, handoffs, or blockers."

  defp prompt_tuning_effect("ceo-owner-signoff"),
    do: "CEO signoff should stay distinct from generic blocked work."

  defp prompt_tuning_effect("cto-review"),
    do: "CTO turns should split and review work with stronger evidence."

  defp prompt_tuning_effect("delivery-evidence"),
    do: "Delivery turns should attach more reviewable evidence."

  defp prompt_tuning_effect("mission-alignment"),
    do: "New work should stay tied to goals and business outcomes."

  defp prompt_tuning_effect("patrol-recovery"),
    do: "Stalled-work wakes should produce decisive recovery actions."

  defp prompt_tuning_effect("blocked-work"),
    do: "Blocked turns should name cause, attempted fix, needs, current state, and next decision."

  defp prompt_tuning_effect("pr-quality"),
    do: "PR work should produce cleaner branch names, titles, bodies, and task lists."

  defp prompt_tuning_effect("stop-condition"),
    do: "Agents should stop only after durable issue state is recorded."

  defp prompt_tuning_effect(_id), do: nil

  defp prompt_tuning_receipt([]), do: nil

  defp prompt_tuning_receipt(results) do
    %{
      agent_count: length(results),
      patch_count: Enum.reduce(results, 0, &(&1.patch_count + &2)),
      agents: results
    }
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
          patches: plan.patches,
          validation_checks: plan.validation_checks
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

  defp repo_delivery_card_class(:ready), do: "border-emerald-500/20 bg-emerald-500/[0.04]"
  defp repo_delivery_card_class(:text_only), do: "border-brand/25 bg-brand/[0.06]"
  defp repo_delivery_card_class(:missing), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp repo_delivery_card_class(_), do: "border-border bg-surface/50"

  defp repo_delivery_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp repo_delivery_badge_class(:text_only), do: "border-brand/25 bg-brand/10 text-brand"

  defp repo_delivery_badge_class(:missing),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp repo_delivery_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp repo_delivery_action_class(:ready),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp repo_delivery_action_class(:text_only),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp repo_delivery_action_class(:missing),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15"

  defp repo_delivery_action_class(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

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

  defp launch_plan_card_class(:danger), do: "border-brand/25 bg-brand/[0.06]"
  defp launch_plan_card_class(:attention), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp launch_plan_card_class(:brand), do: "border-sky-500/25 bg-sky-500/[0.06]"
  defp launch_plan_card_class(:success), do: "border-emerald-500/25 bg-emerald-500/[0.06]"
  defp launch_plan_card_class(_), do: "border-border bg-surface/50"

  defp launch_plan_badge_class(:danger), do: "border-brand/25 bg-brand/10 text-brand"

  defp launch_plan_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp launch_plan_badge_class(:brand), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp launch_plan_badge_class(:success),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp launch_plan_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp launch_plan_step_class(:active), do: "border-sky-500/25 bg-sky-500/[0.06]"
  defp launch_plan_step_class(:pending), do: "border-border bg-canvas/60"
  defp launch_plan_step_class(_), do: "border-border bg-canvas/60"

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
    focused_count = Map.get(launch_preview, :focused_count, 0)

    if focused_count > 0 do
      "Review mode is on. #{focused_dispatch_phrase(focused_count)}; each focused command still runs one issue, and broad launch will take the focused queue first."
    else
      "Review mode is on. This preview shows queue order and preflight checks before you start runtime; focused commands still run one issue first."
    end
    |> maybe_append_launch_limit(launch_preview)
  end

  defp launch_preview_summary(_runtime_mode, launch_preview) do
    "Dispatch can start up to #{launch_preview.max_concurrent} #{plural_noun(launch_preview.max_concurrent, "issue")} per poll. This preview mirrors the dispatcher priority order before any agent is started."
  end

  defp focused_dispatch_phrase(1), do: "1 issue is queued for focused dispatch"

  defp focused_dispatch_phrase(count),
    do: "#{count} #{plural_noun(count, "issue")} are queued for focused dispatch"

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

  defp delegated_work_setup_action?(work) when is_map(work) do
    not Map.get(work, :queueable?, false) and
      (Map.get(work, :setup_blocked?, false) or Map.get(work, :preflight_attention?, false)) and
      present?(preflight_action_target_path(get_in(work, [:preflight, :first_action])))
  end

  defp delegated_work_setup_action?(_work), do: false

  defp delegated_work_setup_action_label(%{setup_blocked?: true}), do: "Fix setup first"

  defp delegated_work_setup_action_label(%{preflight: %{first_action: action}}),
    do: preflight_action_target_label(action)

  defp delegated_work_setup_action_label(_work), do: "Review setup"

  defp delegated_work_setup_action_class(%{setup_blocked?: true}) do
    "rounded-md border border-brand/25 bg-brand/10 px-2.5 py-1.5 text-[11px] font-510 text-brand transition hover:bg-brand/15"
  end

  defp delegated_work_setup_action_class(_work) do
    "rounded-md border border-amber-500/25 bg-amber-500/10 px-2.5 py-1.5 text-[11px] font-510 text-amber-200 transition hover:bg-amber-500/15"
  end

  defp present?(value), do: value not in [nil, ""]

  defp preflight_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp preflight_badge_class(:review_mode),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp preflight_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp preflight_badge_class(:blocked), do: "border-brand/25 bg-brand/10 text-brand"
  defp preflight_badge_class(_), do: "border-border bg-panel text-text-tertiary"

  defp owner_brief_readiness_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp owner_brief_readiness_badge_class(:draft),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp owner_brief_readiness_badge_class(:thin),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp owner_brief_readiness_badge_class(_),
    do: "border-border bg-panel text-text-tertiary"

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

  defp contract_queue_card_class(:missing), do: "border-brand/35 bg-brand/[0.07]"

  defp contract_queue_card_class(:attention),
    do: "border-amber-500/25 bg-amber-500/[0.06]"

  defp contract_queue_card_class(_), do: "border-border bg-surface"

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

  defp ceo_outcome_signal_count(counts) do
    [
      :owner_updates,
      :owner_acceptances,
      :handoffs,
      :decompositions,
      :governance
    ]
    |> Enum.map(&Map.get(counts, &1, 0))
    |> Enum.sum()
  end

  defp ceo_outcome_metric_cards(counts) do
    [
      %{
        label: "Owner updates",
        value: Map.get(counts, :owner_updates, 0),
        detail: "CEO status notes",
        value_class: "text-emerald-300"
      },
      %{
        label: "Acceptances",
        value: Map.get(counts, :owner_acceptances, 0),
        detail: "Owner signoffs",
        value_class: "text-teal-300"
      },
      %{
        label: "Handoffs",
        value: Map.get(counts, :handoffs, 0),
        detail: "Delegated next steps",
        value_class: "text-sky-300"
      },
      %{
        label: "Splits",
        value: Map.get(counts, :decompositions, 0),
        detail: "Child issue plans",
        value_class: "text-brand"
      },
      %{
        label: "Decisions",
        value: Map.get(counts, :governance, 0),
        detail: "Governance moves",
        value_class: "text-violet-300"
      },
      %{
        label: "Active",
        value: Map.get(counts, :running, 0),
        detail: "CEO runs in flight",
        value_class: "text-sky-300"
      },
      %{
        label: "Attention",
        value: Map.get(counts, :attention, 0),
        detail: "Failed or thin turns",
        value_class: "text-amber-300"
      }
    ]
  end

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

  defp ceo_receipt_badge_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp ceo_receipt_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp ceo_receipt_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp repairable_ceo_outcome?(%{outcome: outcome}) when outcome in [:silent, :failed], do: true
  defp repairable_ceo_outcome?(%{receipt: %{status: :attention}}), do: true
  defp repairable_ceo_outcome?(_outcome), do: false

  defp ceo_outcome_repair_label(%{receipt: %{status: :attention}}),
    do: "Fix receipt and relaunch"

  defp ceo_outcome_repair_label(_outcome), do: "Fix and relaunch"

  defp ceo_outcome_repair_detail(%{receipt: %{status: :attention} = receipt}) do
    Map.get(receipt, :repair_prompt) ||
      "Fix the receipt gap above, then restart runtime focused on this issue."
  end

  defp ceo_outcome_repair_detail(_outcome) do
    "Fix the feedback above, then restart runtime focused on this issue."
  end

  defp ceo_flow_badge_class(:setup), do: "border-brand/25 bg-brand/10 text-brand"
  defp ceo_flow_badge_class(:blocked), do: "border-brand/25 bg-brand/10 text-brand"
  defp ceo_flow_badge_class(:attention), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp ceo_flow_badge_class(:owner_signoff), do: "border-teal-500/25 bg-teal-500/10 text-teal-300"
  defp ceo_flow_badge_class(:running), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  defp ceo_flow_badge_class(:launch_ready), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp ceo_flow_badge_class(:delegated_work),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp ceo_flow_badge_class(:observed),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp ceo_flow_badge_class(:needs_issue), do: "border-border bg-surface text-text-tertiary"
  defp ceo_flow_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp ceo_flow_action_class(:danger),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp ceo_flow_action_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15"

  defp ceo_flow_action_class(:brand),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-200 hover:bg-sky-500/15"

  defp ceo_flow_action_class(:success),
    do: "border-teal-500/25 bg-teal-500/10 text-teal-200 hover:bg-teal-500/15"

  defp ceo_flow_action_class(_),
    do: "border-border bg-surface text-text-secondary hover:bg-surface-hover"

  defp ceo_flow_step_class(:complete), do: "border-emerald-500/25 bg-emerald-500/[0.06]"
  defp ceo_flow_step_class(:active), do: "border-sky-500/25 bg-sky-500/[0.06]"
  defp ceo_flow_step_class(:attention), do: "border-amber-500/25 bg-amber-500/[0.06]"
  defp ceo_flow_step_class(:blocked), do: "border-brand/25 bg-brand/[0.07]"
  defp ceo_flow_step_class(:missing), do: "border-border bg-surface/45"
  defp ceo_flow_step_class(_), do: "border-border bg-surface/45"

  defp ceo_flow_step_value_class(:complete), do: "text-emerald-300"
  defp ceo_flow_step_value_class(:active), do: "text-sky-300"
  defp ceo_flow_step_value_class(:attention), do: "text-amber-300"
  defp ceo_flow_step_value_class(:blocked), do: "text-brand"
  defp ceo_flow_step_value_class(:missing), do: "text-text-quaternary"
  defp ceo_flow_step_value_class(_), do: "text-text-tertiary"

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

  defp new_agent_query_for_gap(gap) do
    %{
      role: to_string(gap.role),
      name: gap.label,
      runtime_profile_id: "openai-chat-qwen-dashscope-flash",
      return_to: "/operations#runtime-staffing-gaps"
    }
    |> maybe_put_parent_query(gap.suggested_parent)
  end

  defp maybe_put_parent_query(query, %{id: id}) when is_binary(id),
    do: Map.put(query, :parent_id, id)

  defp maybe_put_parent_query(query, _), do: query

  defp first_staffing_gap_label(%{role_demand_gaps: [gap | _]}), do: "Hire #{gap.label}"
  defp first_staffing_gap_label(_), do: "Hire role"

  defp issue_example_label(%{identifier: identifier, title: title})
       when is_binary(identifier) and identifier != "" do
    "#{identifier} · #{title}"
  end

  defp issue_example_label(%{title: title}), do: title || "Untitled issue"

  defp plural_noun(1, singular, _plural), do: singular
  defp plural_noun(_count, _singular, plural), do: plural

  defp plural_noun(count, singular), do: plural_noun(count, singular, singular <> "s")
end
