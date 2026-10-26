defmodule CymphoWeb.OperationsLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.AgentInstructionTuner
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Inbox
  alias Cympho.Issues
  alias Cympho.Issues.SwarmEvents
  alias Cympho.ReviewNudges
  alias Cympho.RuntimeOperations
  alias Cympho.Wakes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      SwarmEvents.subscribe(socket.assigns.current_company.id)
    end

    {:ok, socket |> assign(:digest_density, "compact") |> assign_snapshot()}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply,
     socket
     |> assign(:digest_density, normalize_digest_density(params["density"]))
     |> assign_snapshot(parent_issue_id: Map.get(params, "parent_issue_id"))}
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

    case RuntimeOperations.recover_company_stale_runs(company_id) do
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
           "Recovered #{recovered} stale/orphaned #{plural_noun(recovered, "run")}, cancelled #{cancelled} stale waiting #{plural_noun(cancelled, "run")}, and cleared #{released} stale checkout #{plural_noun(released, "lock")}. Checked #{stale} stale, #{orphaned} orphaned, #{waiting} waiting, and #{stale_checkouts} checked-out candidates."
         )}

      {:ok, %{recovered: recovered, cancelled: cancelled, released: released, failed: failed}} ->
        {:noreply,
         socket
         |> assign_snapshot()
         |> put_flash(
           :error,
           "Recovered #{recovered}, cancelled #{cancelled}, and cleared #{released} checkout #{plural_noun(released, "lock")}; #{failed} failed to update."
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

  @impl true
  def handle_info({:swarm_event_created, event}, socket) do
    case socket.assigns[:delegated_parent_issue_id] do
      nil ->
        {:noreply, assign_snapshot(socket)}

      parent_issue_id when parent_issue_id == event.parent_issue_id ->
        {:noreply, assign_snapshot(socket, parent_issue_id: event.parent_issue_id)}

      _parent_issue_id ->
        {:noreply, socket}
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
      |> scoped_parent_issue_id(company_id)

    snapshot =
      RuntimeOperations.snapshot(
        company_id,
        opts
        |> Keyword.put(:parent_issue_id, parent_issue_id)
      )

    socket
    |> assign(:page_title, "Health")
    |> assign(:delegated_parent_issue_id, parent_issue_id)
    |> assign_swarm_events(parent_issue_id)
    |> assign(:snapshot, snapshot)
    |> assign(:runtime_mode, snapshot.runtime_mode)
    |> assign(:services, snapshot.services)
    |> assign(:capacity, snapshot.capacity)
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

  defp assign_swarm_events(socket, parent_issue_id) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    events = SwarmEvents.list_for_company_parent(company_id, parent_issue_id, limit: 20)

    assign(socket,
      swarm_events: events,
      swarm_event_rows: events |> Enum.reverse() |> Enum.map(&swarm_event_row/1)
    )
  end

  defp scoped_parent_issue_id(parent_issue_id, company_id)
       when is_binary(parent_issue_id) and is_binary(company_id) do
    with {:ok, parent_issue_id} <- Ecto.UUID.cast(parent_issue_id),
         {:ok, issue} <- Issues.get_company_issue(company_id, parent_issue_id) do
      issue.id
    else
      _ -> nil
    end
  end

  defp scoped_parent_issue_id(_parent_issue_id, _company_id), do: nil

  defp operations_url(density, parent_issue_id) do
    params =
      %{
        density: if(density == "detailed", do: "detailed"),
        parent_issue_id: parent_issue_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Map.new()

    if map_size(params) == 0 do
      ~p"/operations"
    else
      ~p"/operations?#{params}"
    end
  end

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

  defp show_operations_swarm_log?(delegated_work, swarm_event_rows) do
    Map.get(delegated_work || %{}, :filtered?, false) and
      (Map.get(delegated_work || %{}, :swarm_count, 0) > 0 or swarm_event_rows != [])
  end

  defp swarm_event_row(event) do
    %{
      id: event.id,
      type_label: swarm_event_type_label(event.event_type),
      status: event.status || "info",
      message: event.message,
      time: swarm_event_time(event.occurred_at || event.inserted_at),
      chips: swarm_event_chips(event.metadata || %{})
    }
  end

  defp swarm_event_type_label(type) when is_binary(type) do
    type
    |> String.split("_")
    |> Enum.with_index()
    |> Enum.map(fn {word, index} -> swarm_event_type_word(word, index) end)
    |> Enum.join(" ")
  end

  defp swarm_event_type_label(_type), do: "Event"

  defp swarm_event_type_word(word, _index) when word in ["ceo", "cto"],
    do: String.upcase(word)

  defp swarm_event_type_word(word, 0), do: String.capitalize(word)
  defp swarm_event_type_word(word, _index), do: word

  defp swarm_event_time(%DateTime{} = time) do
    time
    |> DateTime.to_iso8601()
    |> String.slice(11, 8)
  end

  defp swarm_event_time(%NaiveDateTime{} = time) do
    time
    |> NaiveDateTime.to_iso8601()
    |> String.slice(11, 8)
  end

  defp swarm_event_time(_time), do: "--:--:--"

  defp swarm_event_chips(metadata) when is_map(metadata) do
    [
      swarm_count_chip(metadata, "agent_ids", "agents"),
      swarm_count_chip(metadata, "worker_issue_ids", "workers"),
      swarm_value_chip(metadata, "agent_count", "workers"),
      swarm_value_chip(metadata, "mix_rows", "mix rows"),
      swarm_prefixed_chip(metadata, "proxy_mode", "proxy"),
      swarm_prefixed_chip(metadata, "worker_index", "worker"),
      swarm_prefixed_chip(metadata, "role", "role"),
      swarm_short_chip(metadata, "summary"),
      swarm_short_chip(metadata, "reason"),
      swarm_value_chip(metadata, "queued_count", "queued"),
      swarm_value_chip(metadata, "failed_count", "failed")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.take(4)
  end

  defp swarm_event_chips(_metadata), do: []

  defp swarm_count_chip(metadata, key, label) do
    case swarm_metadata_value(metadata, key) do
      values when is_list(values) -> "#{length(values)} #{label}"
      _value -> nil
    end
  end

  defp swarm_value_chip(metadata, key, label) do
    case swarm_metadata_value(metadata, key) do
      value when is_integer(value) -> "#{value} #{label}"
      value when is_binary(value) and value != "" -> "#{value} #{label}"
      _value -> nil
    end
  end

  defp swarm_prefixed_chip(metadata, key, label) do
    case swarm_metadata_value(metadata, key) do
      value when is_integer(value) -> "#{label} #{value}"
      value when is_binary(value) and value != "" -> "#{label} #{value}"
      _value -> nil
    end
  end

  defp swarm_short_chip(metadata, key) do
    case swarm_metadata_value(metadata, key) do
      value when is_binary(value) and value != "" ->
        value
        |> String.replace(~r/\s+/, " ")
        |> String.slice(0, 90)

      _value ->
        nil
    end
  end

  defp swarm_metadata_value(metadata, key) do
    Map.get(metadata, key) || Map.get(metadata, swarm_metadata_atom_key(key))
  end

  defp swarm_metadata_atom_key("agent_ids"), do: :agent_ids
  defp swarm_metadata_atom_key("worker_issue_ids"), do: :worker_issue_ids
  defp swarm_metadata_atom_key("agent_count"), do: :agent_count
  defp swarm_metadata_atom_key("mix_rows"), do: :mix_rows
  defp swarm_metadata_atom_key("proxy_mode"), do: :proxy_mode
  defp swarm_metadata_atom_key("worker_index"), do: :worker_index
  defp swarm_metadata_atom_key("role"), do: :role
  defp swarm_metadata_atom_key("summary"), do: :summary
  defp swarm_metadata_atom_key("reason"), do: :reason
  defp swarm_metadata_atom_key("queued_count"), do: :queued_count
  defp swarm_metadata_atom_key("failed_count"), do: :failed_count
  defp swarm_metadata_atom_key(_key), do: nil

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

        with {:ok, baseline} <-
               Agents.create_config_revision(agent, %{
                 source: "prompt_tuning_baseline",
                 created_by_user_id: current_user_id(socket)
               }),
             {:ok, updated_agent} <- Agents.update_agent(agent, %{instructions: instructions}),
             {:ok, _revision} <-
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
             revision: baseline.version,
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

  attr :priority, :atom, required: true
  attr :label, :string, required: true

  # Task's priority bars (v7 §1.5) beside the word.
  defp pri(assigns) do
    assigns = assign(assigns, :on, priority_bars(assigns.priority))

    ~H"""
    <span class="op-pri">
      <span class="pri" aria-hidden="true"><i :for={n <- 1..4} class={n <= @on && "on"}></i></span>{@label}
    </span>
    """
  end

  defp priority_bars(:critical), do: 4
  defp priority_bars(:high), do: 3
  defp priority_bars(:medium), do: 2
  defp priority_bars(_priority), do: 1

  ## Tones as status shapes (v7 §1.5): each runtime domain keeps its own
  ## mapping, so a word like :running reads as it did in its old colour.

  defp capsule_state(:autonomous), do: :working
  defp capsule_state(:degraded), do: :waiting
  defp capsule_state(_status), do: :idle

  defp row_kind(:danger), do: :problem
  defp row_kind(:attention), do: :question
  defp row_kind(_tone), do: :neutral

  # The tinted well under a launch step or delivery lane: only problems tint.
  defp well_tone(:stopped), do: "p"
  defp well_tone(:waiting), do: "w"
  defp well_tone(_kind), do: nil

  defp enablement_kind(:ready), do: :done
  defp enablement_kind(:running), do: :working
  defp enablement_kind(:blocked), do: :waiting
  defp enablement_kind(_status), do: :idle

  defp launch_plan_kind(:danger), do: :stopped
  defp launch_plan_kind(:attention), do: :waiting
  defp launch_plan_kind(:success), do: :done
  defp launch_plan_kind(_tone), do: :idle

  defp preflight_kind(:ready), do: :done
  defp preflight_kind(:attention), do: :waiting
  defp preflight_kind(:blocked), do: :stopped
  defp preflight_kind(_status), do: :idle

  defp readiness_kind(:ok), do: :done
  defp readiness_kind(:attention), do: :waiting
  defp readiness_kind(:blocked), do: :stopped
  defp readiness_kind(_status), do: :idle

  defp brief_kind(:ready), do: :done
  defp brief_kind(:draft), do: :waiting
  defp brief_kind(:thin), do: :stopped
  defp brief_kind(_status), do: :idle

  defp ceo_flow_kind(stage) when stage in [:setup, :blocked], do: :stopped

  defp ceo_flow_kind(stage) when stage in [:attention, :delegated_work, :owner_signoff],
    do: :waiting

  defp ceo_flow_kind(:running), do: :working
  defp ceo_flow_kind(:observed), do: :done
  defp ceo_flow_kind(_stage), do: :idle

  defp ceo_step_kind(:complete), do: :done
  defp ceo_step_kind(:active), do: :working
  defp ceo_step_kind(:attention), do: :waiting
  defp ceo_step_kind(:blocked), do: :stopped
  defp ceo_step_kind(_state), do: :idle

  defp nudge_kind(:queued), do: :waiting
  defp nudge_kind(:running), do: :working
  defp nudge_kind(:stale), do: :stopped
  defp nudge_kind(:cleared), do: :done
  defp nudge_kind(_lifecycle), do: :idle

  defp contract_kind(:missing), do: :stopped
  defp contract_kind(:attention), do: :waiting
  defp contract_kind(_status), do: :idle

  defp prompt_kind(:ready), do: :done
  defp prompt_kind(status) when status in [:needs_tuning, :regressed], do: :waiting
  defp prompt_kind(status) when status in [:guardrail_risk, :eval_gap], do: :stopped
  defp prompt_kind(_status), do: :idle

  defp ceo_outcome_kind(outcome)
       when outcome in [:owner_update, :owner_accepted, :handoff, :decomposition, :governance],
       do: :done

  defp ceo_outcome_kind(outcome) when outcome in [:owner_revision, :blocked, :silent],
    do: :waiting

  defp ceo_outcome_kind(:running), do: :working
  defp ceo_outcome_kind(:failed), do: :stopped
  defp ceo_outcome_kind(_outcome), do: :idle

  defp receipt_kind(:ok), do: :done
  defp receipt_kind(:attention), do: :waiting
  defp receipt_kind(_status), do: :idle

  defp doctor_kind(:critical), do: :stopped
  defp doctor_kind(:warning), do: :waiting
  defp doctor_kind(:ok), do: :done
  defp doctor_kind(_level), do: :idle

  defp service_kind(:running), do: :done
  defp service_kind(:not_running), do: :stopped
  defp service_kind(_status), do: :idle

  defp capacity_kind(:safe), do: :done
  defp capacity_kind(:watch), do: :waiting
  defp capacity_kind(:high), do: :stopped
  defp capacity_kind(_level), do: :idle

  defp repo_delivery_kind(:ready), do: :done
  defp repo_delivery_kind(status) when status in [:text_only, :missing], do: :waiting
  defp repo_delivery_kind(_status), do: :idle

  defp health_kind(:healthy), do: :done
  defp health_kind(:degraded), do: :waiting
  defp health_kind(:unavailable), do: :stopped
  defp health_kind(_status), do: :idle

  defp swarm_kind("success"), do: :done
  defp swarm_kind("warning"), do: :waiting
  defp swarm_kind("error"), do: :stopped
  defp swarm_kind(_status), do: :idle

  defp now_waiting_count(wake_queue, review_nudges) do
    Map.get(wake_queue.counts, :pending_comments, 0) +
      Map.get(review_nudges.counts, :active, 0)
  end

  defp now_stale_count(capacity, wake_queue) do
    Map.get(capacity, :stale_checked_out_issues, 0) +
      Map.get(wake_queue.counts, :stale_comments, 0)
  end

  # Two subheads replace the per-card "Core launch"/"Optional automation" pill,
  # which carried no information a card-level grouping cannot.
  defp service_groups(services) do
    [
      %{
        label: "Core launch",
        hint: "Required before agents pick up queued work.",
        services: Enum.filter(services, &(&1.purpose == :core))
      },
      %{
        label: "Optional automation",
        hint: "Extra loops that wake agents on their own.",
        services: Enum.filter(services, &(&1.purpose == :automation))
      }
    ]
    |> Enum.reject(&(&1.services == []))
  end

  defp simple_action_queue(
         delegated_work,
         owner_signoffs,
         ceo_outcomes,
         runtime_enablement,
         launch_plan
       ) do
    rows =
      [
        simple_runtime_cleanup_row(runtime_enablement),
        simple_delegated_work_row(delegated_work),
        simple_owner_signoff_row(owner_signoffs),
        simple_ceo_receipt_row(ceo_outcomes),
        simple_launch_row(launch_plan, runtime_enablement)
      ]
      |> Enum.reject(&is_nil/1)

    case rows do
      [] -> [simple_steady_row()]
      rows -> Enum.take(rows, 4)
    end
  end

  defp simple_runtime_cleanup_row(%{status: :blocked, cleanup_count: count}) when count > 0 do
    %{
      key: "cleanup",
      tone: :danger,
      icon: "i-halt",
      eyebrow: "Runtime",
      title: "Recover stale runtime state",
      detail:
        "#{count} active or stale #{plural_noun(count, "slot")} must be released before launch.",
      action_label: "Recover",
      action_event: "recover_stale_runs",
      action_path: nil
    }
  end

  defp simple_runtime_cleanup_row(_runtime_enablement), do: nil

  defp simple_delegated_work_row(%{queueable_count: count} = delegated_work) when count > 0 do
    %{
      key: "delegated",
      tone: :attention,
      icon: "i-tasks",
      eyebrow: "Delegated",
      title: "#{count} runnable delegated #{plural_noun(count, "item")}",
      detail: simple_delegated_runnable_detail(delegated_work),
      action_label: "Focus queue",
      action_event: "prioritize_delegated_work",
      action_path: nil
    }
  end

  defp simple_delegated_work_row(%{setup_blocked_count: count}) when count > 0 do
    %{
      key: "delegated",
      tone: :danger,
      icon: "i-settings",
      eyebrow: "Delegated",
      title: "#{count} setup #{plural_noun(count, "blocker")}",
      detail: "Something in the setup is blocking these from running.",
      action_label: "Fix setup",
      action_event: nil,
      action_path: simple_visible_ops_path("#runtime-launch-checklist")
    }
  end

  defp simple_delegated_work_row(%{count: count}) when count > 0 do
    %{
      key: "delegated",
      tone: :attention,
      icon: "i-tasks",
      eyebrow: "Delegated",
      title: "#{count} delegated #{plural_noun(count, "item")} open",
      detail: "Work your agents handed to each other — check what's stuck or waiting.",
      action_label: "Open queue",
      action_event: nil,
      action_path: simple_visible_ops_path("#delegated-work-queue")
    }
  end

  defp simple_delegated_work_row(_delegated_work), do: nil

  defp simple_delegated_runnable_detail(%{setup_blocked_count: setup_blocked})
       when setup_blocked > 0 do
    "Ready to run now; #{setup_blocked} setup #{plural_noun(setup_blocked, "blocker")} can be fixed from the queue."
  end

  defp simple_delegated_runnable_detail(_delegated_work) do
    "Ready to run — start these so reviews have real work to look at."
  end

  defp simple_owner_signoff_row(%{count: count}) when count > 0 do
    %{
      key: "owner-signoff",
      tone: :attention,
      icon: "i-check",
      eyebrow: "Owner",
      title: "#{count} CEO #{plural_noun(count, "update")} waiting",
      detail: "Your CEO wants a decision — accept, or ask for another pass.",
      action_label: "Review",
      action_event: nil,
      action_path: simple_visible_ops_path("#owner-signoff-queue")
    }
  end

  defp simple_owner_signoff_row(_owner_signoffs), do: nil

  defp simple_ceo_receipt_row(%{counts: %{receipt_incomplete: count}}) when count > 0 do
    %{
      key: "ceo-receipts",
      tone: :attention,
      icon: "i-doc-check",
      eyebrow: "CEO",
      title: "#{count} receipt #{plural_noun(count, "gap")}",
      detail: "Some CEO updates are missing proof of what actually happened.",
      action_label: "Inspect",
      action_event: nil,
      action_path: simple_visible_ops_path("#ceo-outcome-monitor")
    }
  end

  defp simple_ceo_receipt_row(_ceo_outcomes), do: nil

  defp simple_launch_row(%{status: :idle}, %{status: :running}), do: nil

  defp simple_launch_row(
         %{label: label, summary: summary, target_path: target_path, tone: tone},
         %{
           status: status
         }
       )
       when status in [:ready, :blocked] do
    %{
      key: "launch",
      tone: tone,
      icon: "i-term",
      eyebrow: "Launch",
      title: label,
      detail: summary,
      action_label: "Open",
      action_event: nil,
      action_path: simple_visible_ops_path(target_path || "#runtime-launch-checklist")
    }
  end

  defp simple_launch_row(_launch_plan, _runtime_enablement), do: nil

  defp simple_steady_row do
    %{
      key: "steady",
      tone: :ok,
      icon: "i-check",
      eyebrow: "Steady",
      title: "No urgent operations",
      detail: "Nothing needs you — everything is either running or done.",
      action_label: "Details",
      action_event: nil,
      action_path: simple_visible_ops_path("#runtime-launch-checklist")
    }
  end

  defp simple_action_queue_title([%{key: "steady"}]), do: "All quiet"

  defp simple_action_queue_title(rows) do
    "#{length(rows)} #{plural_noun(length(rows), "thing")} to do"
  end

  # ── Simple-mode copy ────────────────────────────────────────────
  # Runtime actions are named for the machine ("Enable autonomous dispatch").
  # These map the handful that reach simple mode onto what the owner is
  # actually deciding. Anything unmapped passes through unchanged.

  defp simple_runtime_mode_label(%{status: :review}), do: "Nothing is running"
  defp simple_runtime_mode_label(%{status: :degraded}), do: "Working, but not fully set up"
  defp simple_runtime_mode_label(%{status: :autonomous}), do: "The team is working"
  defp simple_runtime_mode_label(%{label: label}), do: label

  defp simple_operations_title("Enable autonomous dispatch"), do: "Turn the team on"
  defp simple_operations_title("Restart with runtime enabled"), do: "Turn the team on"
  defp simple_operations_title("Resume company runtime"), do: "Unpause the team"
  defp simple_operations_title("Add an agent"), do: "Add someone to the team"
  defp simple_operations_title(title), do: title

  defp simple_operations_body("Enable autonomous dispatch", _body),
    do: "Finish the setup items below, then start the team."

  defp simple_operations_body("Restart with runtime enabled", _body),
    do: "Finish the setup items below, then start the team."

  defp simple_operations_body(_title, body), do: body

  defp simple_operations_target_label("Review service gates"), do: "See what's missing"
  defp simple_operations_target_label("Open launch checklist"), do: "See the steps"
  defp simple_operations_target_label(label), do: label

  # An anchor with a page of its own goes to that page; any other anchor stays an
  # in-page jump (sending it to /operations would only reload the page it is on).
  # Every such jump lands on an Advanced-only section, so the template hides that
  # Next step in Simple mode. An action without a target has nothing to press.
  defp next_step_path(nil), do: nil

  defp next_step_path(target) do
    case simple_visible_ops_path(target) do
      "/operations" when is_binary(target) ->
        if anchor_path?(target), do: target, else: "/operations"

      path ->
        path
    end
  end

  # Simple mode hides advanced-only Operations anchors. Send the owner to a
  # page they can actually see.
  defp simple_visible_ops_path("#runtime-launch-checklist"), do: "/settings/adapters"
  defp simple_visible_ops_path("#delegated-work-queue"), do: "/kanban"
  defp simple_visible_ops_path("#owner-signoff-queue"), do: "/inbox"
  defp simple_visible_ops_path("#ceo-outcome-monitor"), do: "/inbox"
  defp simple_visible_ops_path("#" <> _), do: "/operations"
  defp simple_visible_ops_path(path) when is_binary(path), do: path
  defp simple_visible_ops_path(_), do: "/operations"

  defp launch_preview_summary(%{status: :review}, launch_preview) do
    focused_count = Map.get(launch_preview, :focused_count, 0)

    if focused_count > 0 do
      "Review mode is on. #{focused_dispatch_phrase(focused_count)}; each focused command still runs one issue, and broad launch will take the focused queue first."
    else
      "Review mode is on. This preview shows queue order and preflight checks before you start runtime; focused commands still run one issue first."
    end
  end

  defp launch_preview_summary(_runtime_mode, _launch_preview) do
    "This preview mirrors company queue order and preflight checks before any agent is started."
  end

  defp focused_dispatch_phrase(1), do: "1 issue is queued for focused dispatch"

  defp focused_dispatch_phrase(count),
    do: "#{count} #{plural_noun(count, "issue")} are queued for focused dispatch"

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

  # A queue is usually stuck behind one environment problem — a single missing
  # CLI, one unset key — so every candidate row printed the same sentence. Return
  # that sentence only when it is common to the whole queue; any candidate that
  # differs (or has no action) keeps every row explaining itself individually.
  defp shared_preflight_blocker([_, _ | _] = candidates) do
    candidates
    |> Enum.map(fn
      %{preflight: %{first_action: %{detail: detail}}} when is_binary(detail) -> detail
      _ -> nil
    end)
    |> Enum.uniq()
    |> case do
      [detail] when is_binary(detail) -> detail
      _ -> nil
    end
  end

  defp shared_preflight_blocker(_candidates), do: nil

  # Same idea as shared_preflight_blocker/1: with one runtime profile in play
  # every agent row carried an identical slot count, so the roster repeated
  # "1 local CLI slot" once per agent instead of stating the capacity once.
  defp shared_slot_label([_, _ | _] = agents) do
    agents
    |> Enum.map(fn
      %{pressure: %{slot_label: label}} when is_binary(label) -> label
      _ -> nil
    end)
    |> Enum.uniq()
    |> case do
      [label] when is_binary(label) -> label
      _ -> nil
    end
  end

  defp shared_slot_label(_agents), do: nil

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

  defp present?(value), do: value not in [nil, ""]

  defp anchor_path?(path) when is_binary(path), do: String.starts_with?(path, "#")
  defp anchor_path?(_), do: false

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
        detail: "CEO status notes"
      },
      %{
        label: "Acceptances",
        value: Map.get(counts, :owner_acceptances, 0),
        detail: "Owner signoffs"
      },
      %{
        label: "Handoffs",
        value: Map.get(counts, :handoffs, 0),
        detail: "Delegated next steps"
      },
      %{
        label: "Splits",
        value: Map.get(counts, :decompositions, 0),
        detail: "Child issue plans"
      },
      %{
        label: "Decisions",
        value: Map.get(counts, :governance, 0),
        detail: "Governance moves"
      },
      %{
        label: "Active",
        value: Map.get(counts, :running, 0),
        detail: "CEO runs in flight"
      },
      %{
        label: "Attention",
        value: Map.get(counts, :attention, 0),
        detail: "Failed or thin turns"
      }
    ]
  end

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

  defp recent_capacity_denial?(capacity, launch_preview, wake_queue, review_nudges) do
    admission = Map.get(capacity, :admission, %{})

    queued_work =
      Map.get(launch_preview, :total_candidates, 0) +
        now_waiting_count(wake_queue, review_nudges)

    queued_work > 0 and Map.get(admission, :recent_denial?) == true
  end

  defp configured_slots_detail(capacity) do
    "#{capacity.gateway_slots} online-provider configured"
  end

  defp simple_admission_message(_admission) do
    "Shared runtime capacity recently delayed work. It will retry when safe capacity is available."
  end

  defp admission_status_label(%{status: :available}), do: "Managed"
  defp admission_status_label(_admission), do: "Temporarily unavailable"

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
