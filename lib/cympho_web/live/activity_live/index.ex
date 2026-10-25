defmodule CymphoWeb.ActivityLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Activities
  alias Cympho.Agents
  alias Cympho.Companies

  @issue_actions ~w(
    created title_changed description_changed priority_changed status_changed
    assigned unassigned blocker_added blocker_removed comment_added work_product_created
  )
  @cost_actions ~w(cost_incurred budget_threshold_exceeded)
  @runtime_actions ~w(heartbeat_started heartbeat_completed heartbeat_failed)
  # Events that report a problem: their row's tile is the problem tone.
  @problem_actions ~w(heartbeat_failed budget_threshold_exceeded)

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    socket =
      socket
      |> assign(:page_title, "Activity")
      |> assign(:company_id, company_id)
      |> assign(:actor_names, actor_names(company_id))
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
    |> assign(
      :activity_command,
      build_activity_command(snapshot, filtered?, socket.assigns.actor_names)
    )
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

  defp build_activity_command(%{total: 0}, true, _names) do
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

  defp build_activity_command(%{total: 0}, false, _names), do: empty_activity_command()

  defp build_activity_command(%{by_action: by_action, latest: latest}, _filtered?, names) do
    counts = command_counts(by_action)
    focus = activity_focus(latest, names)

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
            detail: "Everything that changed recently, newest first.",
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
        "Cost and budget-threshold events that can change system status.",
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

  defp activity_focus(nil, _names), do: %{label: nil, detail: nil}

  defp activity_focus(activity, names) do
    label =
      case activity.issue do
        %{identifier: identifier, title: title} when identifier not in [nil, ""] ->
          "#{identifier} · #{title}"

        %{title: title} ->
          title

        _ ->
          "Issue removed"
      end

    %{
      label: label,
      detail: "#{format_action(activity.action)} · #{actor_name(activity, names)}"
    }
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

  defp active_filter_count(action, actor_type),
    do: Enum.count([action, actor_type], &(&1 not in [nil, ""]))

  # The row's sentence (v7 G4): the action, with the detail its metadata adds
  # (what a status or priority changed to, the amount, the work product).
  defp activity_title(%{action: action, metadata: metadata}) do
    label = format_action(action)

    case action do
      "title_changed" ->
        with_suffix(
          label,
          change(quoted(metadata, "from"), quoted(metadata, "to")),
          &"#{&1} #{&2}"
        )

      changed when changed in ~w(status_changed priority_changed) ->
        with_suffix(
          label,
          change(detail(metadata, "from"), detail(metadata, "to")),
          &"#{&1} #{&2}"
        )

      _ ->
        with_suffix(label, action_suffix(action, metadata), &"#{&1}: #{&2}")
    end
  end

  defp change(_from, nil), do: nil
  defp change(nil, to), do: "to #{to}"
  defp change(from, to), do: "from #{from} to #{to}"

  defp action_suffix("cost_incurred", metadata), do: detail(metadata, "amount")

  defp action_suffix("budget_threshold_exceeded", metadata),
    do: detail(metadata, "threshold_type")

  defp action_suffix("work_product_created", metadata), do: written(metadata, "title")
  defp action_suffix(_action, _metadata), do: nil

  defp with_suffix(label, nil, _join), do: label
  defp with_suffix(label, suffix, join), do: join.(label, suffix)

  # A printable metadata value in words, or nil (a nested map or list is not a sentence part).
  defp detail(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_binary(value) and value != "" -> String.replace(value, "_", " ")
      value when is_number(value) -> to_string(value)
      %Decimal{} = value -> Decimal.to_string(value)
      _ -> nil
    end
  end

  # A name someone wrote (a title), kept as written: its underscores are the author's.
  defp written(metadata, key) do
    case metadata_value(metadata, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp quoted(metadata, key), do: if(title = written(metadata, key), do: "“#{title}”")

  attr :issue, :map, required: true

  # One line, so the underline ends with the title (a formatted multi-line link renders a trailing space).
  defp task_link(assigns) do
    ~H"""
    <.link class="ul" navigate={~p"/issues/#{@issue.id}"}>{@issue.title}</.link>
    """
  end

  defp problem_action?(action), do: action in @problem_actions

  # The row's kind tile: a problem, else the family the event belongs to.
  defp activity_icon(action) when action in @problem_actions, do: "i-alert"

  defp activity_icon(action) do
    case activity_category(action) do
      :issue -> "i-tasks"
      :governance -> "i-shield"
      :cost -> "i-spend"
      :runtime -> "i-term"
      :other -> "i-doc-check"
    end
  end

  defp actor_name(%{actor_type: "system"}, _names), do: "System"

  defp actor_name(%{actor_type: "agent", metadata: metadata, actor_id: id}, names),
    do:
      metadata_value(metadata, "agent_name") || names[{"agent", id}] ||
        short_identity("Agent", id)

  defp actor_name(%{actor_type: "user", metadata: metadata, actor_id: id}, names),
    do:
      metadata_value(metadata, "user_name") || names[{"user", id}] ||
        short_identity("User", id)

  defp actor_name(%{actor_type: type, actor_id: id}, _names), do: short_identity(type, id)

  # Rows store only the actor's id. Names come from the company's own members
  # and agents, so an id from outside the company keeps its short form.
  defp actor_names(company_id) when is_binary(company_id) do
    users =
      for %{user_id: id, user: %{name: name}} <- Companies.list_memberships(company_id),
          name not in [nil, ""],
          do: {{"user", id}, name}

    agents =
      for agent <- Agents.list_agents_by_company(company_id),
          do: {{"agent", agent.id}, agent.name}

    Map.new(users ++ agents)
  end

  defp actor_names(_company_id), do: %{}

  defp metadata_value(metadata, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, String.to_atom(key))

  defp metadata_value(_metadata, _key), do: nil

  defp short_identity(type, nil), do: String.capitalize(to_string(type))

  defp short_identity(type, id),
    do: "#{String.capitalize(to_string(type))} #{String.slice(id, 0, 8)}"
end
