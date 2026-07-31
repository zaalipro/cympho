defmodule CymphoWeb.ActivityLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Activities

  @issue_actions ~w(
    created title_changed description_changed priority_changed status_changed
    assigned unassigned blocker_added blocker_removed comment_added work_product_created
  )
  @cost_actions ~w(cost_incurred budget_threshold_exceeded)
  @runtime_actions ~w(heartbeat_started heartbeat_completed heartbeat_failed)
  # Only actions whose metadata says something the action label does not. The
  # rest ("assigned" -> "Assigned to agent") just restated the row above.
  @detail_actions ~w(
    title_changed status_changed priority_changed cost_incurred
    budget_threshold_exceeded work_product_created
  )

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    socket =
      socket
      |> assign(:page_title, "Activity Feed")
      |> assign(:company_id, company_id)
      |> assign(:filter_action, "")
      |> assign(:filter_actor_type, "")
      |> assign(:infinite_scroll, %{})
      |> assign(:activity_command, empty_activity_command())
      |> assign(:activity_audit_lanes, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:filter_action, params["filter_action"] || "")
      |> assign(:filter_actor_type, params["filter_actor_type"] || "")
      |> assign_activity_command()

    {:noreply, init_stream(socket, :activities, &fetch_activities(socket, &1))}
  end

  @impl true
  def handle_event("filter", params, socket) do
    action = Map.get(params, "filter_action", socket.assigns.filter_action)
    actor_type = Map.get(params, "filter_actor_type", socket.assigns.filter_actor_type)
    {:noreply, push_patch(socket, to: build_url(action, actor_type))}
  end

  def handle_event("clear_filters", _, socket) do
    {:noreply, push_patch(socket, to: ~p"/activity")}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :activities, &fetch_activities(socket, &1))}
  end

  # Filter forms filter live via phx-change; phx-submit="prevent" only suppresses
  # a full-page submit on Enter, so this is intentionally a no-op.
  def handle_event("prevent", _params, socket), do: {:noreply, socket}

  defp fetch_activities(socket, cursor) do
    Activities.list_company_activities_page(
      socket.assigns.company_id,
      [after: cursor] ++ activity_filter_opts(socket)
    )
  end

  defp assign_activity_command(socket) do
    snapshot =
      Activities.company_activity_snapshot(
        socket.assigns.company_id,
        activity_filter_opts(socket)
      )

    filtered? = filters_active?(socket)

    socket
    |> assign(:activity_command, build_activity_command(snapshot, filtered?))
    |> assign(:activity_audit_lanes, build_activity_audit_lanes(snapshot, filtered?))
  end

  defp activity_filter_opts(socket) do
    []
    |> maybe_opt(:action, socket.assigns.filter_action)
    |> maybe_opt(:actor_type, socket.assigns.filter_actor_type)
  end

  defp maybe_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp filters_active?(socket),
    do:
      socket.assigns.filter_action not in [nil, ""] or
        socket.assigns.filter_actor_type not in [nil, ""]

  defp empty_activity_command do
    %{
      tone: :idle,
      badge: "Empty",
      heading: "No company activity has been captured yet",
      detail:
        "Create the first issue or launch runtime; this feed becomes the owner-readable record of what changed.",
      focus_label: nil,
      focus_detail: nil,
      action_path: ~p"/issues/new",
      action_label: "Create issue"
    }
  end

  defp build_activity_command(%{total: 0}, true) do
    %{
      empty_activity_command()
      | tone: :filtered,
        badge: "Filtered",
        heading: "No matching activity in this view",
        detail:
          "The activity log may still have events outside the current action or actor filter.",
        action_path: ~p"/activity",
        action_label: "Clear filters"
    }
  end

  defp build_activity_command(%{total: 0}, false), do: empty_activity_command()

  defp build_activity_command(%{by_action: by_action, latest: latest}, _filtered?) do
    counts = command_counts(by_action)
    focus = activity_focus(latest)

    command =
      cond do
        action_count(by_action, "budget_threshold_exceeded") > 0 ->
          %{
            tone: :danger,
            badge: "Budget",
            heading: "Review budget threshold activity before the next run",
            detail:
              "Spend crossed a configured threshold. Check the affected issue and adjust budget, model, or runtime scope before letting more autonomous work continue.",
            action_path: ~p"/costs",
            action_label: "Open costs"
          }

        action_count(by_action, "heartbeat_failed") > 0 ->
          %{
            tone: :danger,
            badge: "Runtime",
            heading: "Investigate failed runtime activity",
            detail:
              "At least one agent turn failed recently. Open Operations, inspect the failure reason, and relaunch only after the provider or command issue is fixed.",
            action_path: ~p"/operations#runtime-launch-checklist",
            action_label: "Open operations"
          }

        counts.governance > 0 ->
          %{
            tone: :review,
            badge: "Governance",
            heading: "Review recent governance decisions",
            detail:
              "Approval activity changed the execution path. Confirm the decision trail before closing issues or starting dependent runtime work.",
            action_path: ~p"/reviews",
            action_label: "Open reviews"
          }

        counts.cost > 0 ->
          %{
            tone: :attention,
            badge: "Spend",
            heading: "Check recent spend events",
            detail:
              "Cost activity is present in the company log. Use the cost view to confirm whether usage matches the current plan.",
            action_path: ~p"/costs",
            action_label: "Open costs"
          }

        true ->
          %{
            tone: :healthy,
            badge: "Live",
            heading: "Activity stream is recording company work",
            detail:
              "Recent issue, runtime, and governance changes are available here as an owner-readable audit trail.",
            action_path: ~p"/activity#activity-feed",
            action_label: "Review feed"
          }
      end

    Map.merge(command, %{focus_label: focus.label, focus_detail: focus.detail})
  end

  defp build_activity_audit_lanes(%{by_action: by_action}, filtered?) do
    counts = command_counts(by_action)

    [
      activity_lane(
        :issue,
        "Issue changes",
        counts.issue,
        "Title, status, assignment, comments, blockers, and artifact events.",
        by_action,
        filtered?
      ),
      activity_lane(
        :governance,
        "Governance decisions",
        counts.governance,
        "Approvals, rejections, requested changes, and resolved governance events.",
        by_action,
        filtered?
      ),
      activity_lane(
        :cost,
        "Spend events",
        counts.cost,
        "Cost and budget-threshold events that can change launch posture.",
        by_action,
        filtered?
      ),
      activity_lane(
        :runtime,
        "Runtime events",
        counts.runtime,
        "Agent heartbeat starts, completions, and failures.",
        by_action,
        filtered?
      ),
      activity_lane(
        :other,
        "Other events",
        counts.other,
        "Feedback, custom markers, and less common audit events.",
        by_action,
        filtered?
      )
    ]
  end

  defp activity_lane(category, label, count, summary, by_action, filtered?) do
    action = top_action_for_category(by_action, category)

    %{
      category: category,
      label: label,
      count: count,
      summary: summary,
      action_label: activity_lane_action_label(action, filtered?),
      action_path: activity_lane_action_path(action, filtered?),
      state_label: activity_lane_state_label(count, filtered?),
      # An empty lane in an unfiltered view needs no pill; "filtered out" does.
      show_state?: count > 0 or filtered?
    }
  end

  defp top_action_for_category(by_action, category) do
    by_action
    |> Enum.filter(fn {action, count} -> count > 0 and activity_category(action) == category end)
    |> Enum.sort_by(fn {action, count} -> {-count, action} end)
    |> case do
      [{action, _count} | _] -> action
      [] -> nil
    end
  end

  defp activity_lane_action_label(_action, true), do: "Clear filters"
  defp activity_lane_action_label(nil, _filtered?), do: "Open feed"

  defp activity_lane_action_label(action, _filtered?) do
    "Show #{format_action(action) |> String.downcase()}"
  end

  defp activity_lane_action_path(_action, true), do: ~p"/activity"
  defp activity_lane_action_path(nil, _filtered?), do: ~p"/activity#activity-feed"

  defp activity_lane_action_path(action, _filtered?) do
    ~p"/activity?#{%{filter_action: action}}"
  end

  defp activity_lane_state_label(0, true), do: "Filtered out"
  defp activity_lane_state_label(0, _filtered?), do: "Clear"
  defp activity_lane_state_label(_count, true), do: "Filtered"
  defp activity_lane_state_label(_count, _filtered?), do: "Review"

  defp command_counts(by_action) do
    Enum.reduce(by_action, %{issue: 0, governance: 0, cost: 0, runtime: 0, other: 0}, fn
      {action, count}, acc ->
        Map.update!(acc, activity_category(action), &(&1 + count))
    end)
  end

  defp activity_category(action) when action in @cost_actions, do: :cost
  defp activity_category(action) when action in @runtime_actions, do: :runtime
  defp activity_category(action) when action in @issue_actions, do: :issue
  defp activity_category("approval_" <> _), do: :governance
  defp activity_category(_action), do: :other

  defp action_count(by_action, action), do: Map.get(by_action, action, 0)

  defp activity_focus(nil), do: %{label: nil, detail: nil}

  defp activity_focus(activity) do
    label =
      case activity.issue do
        %{identifier: identifier, title: title} when identifier not in [nil, ""] ->
          "#{identifier} · #{title}"

        %{title: title} ->
          title

        _ ->
          "Issue removed"
      end

    %{label: label, detail: "#{format_action(activity.action)} · #{actor_name(activity)}"}
  end

  defp build_url(filter_action, filter_actor_type) do
    query =
      %{
        filter_action: filter_action,
        filter_actor_type: filter_actor_type
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/activity?#{query}"
  end

  defp get_current_company_id(socket) do
    # Try to get company_id from various sources
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  defp format_action(action), do: String.capitalize(String.replace(action, "_", " "))
  defp format_actor_type(type), do: String.capitalize(type)

  defp format_timestamp(nil), do: ""

  defp format_timestamp(datetime) do
    datetime =
      case DateTime.shift_zone(datetime, "America/Los_Angeles") do
        {:ok, shifted} -> shifted
        {:error, _reason} -> datetime
      end

    Calendar.strftime(datetime, "%b %d, %Y %I:%M %p")
  end

  defp activity_icon(action) do
    case action do
      "created" -> "hero-plus-mini"
      "title_changed" -> "hero-pencil-mini"
      "description_changed" -> "hero-document-text-mini"
      "priority_changed" -> "hero-adjustments-horizontal-mini"
      "status_changed" -> "hero-arrow-path-mini"
      "assigned" -> "hero-user-plus-mini"
      "unassigned" -> "hero-user-minus-mini"
      "blocker_added" -> "hero-no-symbol-mini"
      "blocker_removed" -> "hero-check-circle-mini"
      "comment_added" -> "hero-chat-bubble-left-right-mini"
      "approval_created" -> "hero-shield-check-mini"
      "approval_approved" -> "hero-check-badge-mini"
      "approval_rejected" -> "hero-x-circle-mini"
      "approval_requested_changes" -> "hero-pencil-square-mini"
      "approval_resolved" -> "hero-shield-check-mini"
      "heartbeat_started" -> "hero-play-mini"
      "heartbeat_completed" -> "hero-check-badge-mini"
      "heartbeat_failed" -> "hero-exclamation-triangle-mini"
      "cost_incurred" -> "hero-currency-dollar-mini"
      "budget_threshold_exceeded" -> "hero-exclamation-triangle-mini"
      "feedback_submitted" -> "hero-chart-bar-mini"
      "feedback_exported" -> "hero-arrow-down-tray-mini"
      "work_product_created" -> "hero-paper-clip-mini"
      _ -> "hero-bolt-mini"
    end
  end

  defp activity_icon_tone(action) do
    case activity_category(action) do
      :cost -> "bg-amber-500/10 text-amber-300"
      :runtime -> "bg-cyan-500/10 text-cyan-300"
      :governance -> "bg-brand/10 text-brand"
      :issue -> "bg-emerald-500/10 text-emerald-300"
      _ -> "bg-surface-2 text-text-tertiary"
    end
  end

  defp actor_name(%{actor_type: "system"}), do: "System"

  defp actor_name(%{actor_type: "agent", metadata: metadata, actor_id: id}),
    do: metadata_value(metadata, "agent_name") || short_identity("Agent", id)

  defp actor_name(%{actor_type: "user", metadata: metadata, actor_id: id}),
    do: metadata_value(metadata, "user_name") || short_identity("User", id)

  defp actor_name(%{actor_type: type, actor_id: id}), do: short_identity(type, id)

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))

  defp metadata_value(_metadata, _key), do: nil

  defp short_identity(type, nil), do: String.capitalize(to_string(type))

  defp short_identity(type, id),
    do: "#{String.capitalize(to_string(type))} #{String.slice(id, 0, 8)}"

  defp activity_command_badge_class(:danger), do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp activity_command_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp activity_command_badge_class(:review), do: "border-brand/25 bg-brand/10 text-brand"

  defp activity_command_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp activity_command_badge_class(:filtered),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp activity_command_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp activity_command_action_class(:danger),
    do: "border-red-500/30 bg-red-500/10 text-red-200 hover:bg-red-500/15"

  defp activity_command_action_class(:attention),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15"

  defp activity_command_action_class(:review),
    do: "border-brand/30 bg-brand/10 text-brand hover:bg-brand/15"

  defp activity_command_action_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200 hover:bg-emerald-500/15"

  defp activity_command_action_class(:filtered),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-200 hover:bg-blue-500/15"

  defp activity_command_action_class(_),
    do: "border-border bg-surface text-text-secondary hover:bg-surface-hover"

  defp activity_lane_card_class(:issue), do: "border-l-2 border-l-emerald-400/70"
  defp activity_lane_card_class(:governance), do: "border-l-2 border-l-brand/70"
  defp activity_lane_card_class(:cost), do: "border-l-2 border-l-amber-400/70"
  defp activity_lane_card_class(:runtime), do: "border-l-2 border-l-cyan-400/70"
  defp activity_lane_card_class(_), do: ""

  defp activity_lane_count_class(:issue), do: "text-emerald-300"
  defp activity_lane_count_class(:governance), do: "text-brand"
  defp activity_lane_count_class(:cost), do: "text-amber-300"
  defp activity_lane_count_class(:runtime), do: "text-cyan-300"
  defp activity_lane_count_class(_), do: "text-text-primary"

  defp activity_lane_badge_class(_category, 0),
    do: "border-border bg-surface text-text-tertiary"

  defp activity_lane_badge_class(:issue, _count),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp activity_lane_badge_class(:governance, _count),
    do: "border-brand/25 bg-brand/10 text-brand"

  defp activity_lane_badge_class(:cost, _count),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp activity_lane_badge_class(:runtime, _count),
    do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"

  defp activity_lane_badge_class(_category, _count),
    do: "border-border bg-surface text-text-secondary"

  defp activity_detail_visible?(action), do: action in @detail_actions

  defp render_metadata(assigns) do
    ~H"""
    <%= case @action do %>
      <% "title_changed" -> %>
        Changed title from <code class="text-xs bg-surface px-1 rounded">{@metadata["from"]}</code>
        to <code class="text-xs bg-surface px-1 rounded">{@metadata["to"]}</code>
      <% "status_changed" -> %>
        Changed status from <span class="text-xs">{@metadata["from"]}</span>
        to <span class="text-xs">{@metadata["to"]}</span>
      <% "cost_incurred" -> %>
        Incurred cost: <span class="text-xs">{@metadata["amount"]}</span>
      <% "budget_threshold_exceeded" -> %>
        Budget threshold exceeded: <span class="text-xs">{@metadata["threshold_type"]}</span>
      <% "priority_changed" -> %>
        Changed priority from <span class="text-xs">{@metadata["from"]}</span>
        to <span class="text-xs">{@metadata["to"]}</span>
      <% "work_product_created" -> %>
        Attached work product: <span class="text-xs">{@metadata["title"]}</span>
      <% _ -> %>
        <span></span>
    <% end %>
    """
  end
end
