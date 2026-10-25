defmodule CymphoWeb.AuditTrailLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.AuditTrail

  @governance_events ~w(board_approval_created board_approval_vote decision_created decision_reversed)
  @runtime_events ~w(
    orchestrator_session_started
    orchestrator_session_ended
    orchestrator_tool_call
    company_runtime_paused
    company_runtime_resumed
    company_runtime_stopped
  )
  @agent_events ~w(agent_created agent_updated agent_deleted agent_paused agent_resumed agent_terminated)
  @budget_events ~w(budget_threshold_changed)
  @issue_events ~w(issue_created issue_state_transition issue_assigned issue_blocked issue_runtime_paused issue_runtime_resumed issue_unblocked)
  @evidence_events ~w(agent_action_executed comment_created work_product_attached)

  @impl true
  def mount(_params, _session, socket) do
    company_id = get_current_company_id(socket)

    socket =
      socket
      |> assign(:page_title, "Audit log")
      |> assign(:company_id, company_id)
      |> assign(:infinite_scroll, %{})
      |> assign(:filter_event_type, "")
      |> assign(:filter_actor_type, "")
      |> assign(:filter_actor_id, "")
      |> assign(:filter_resource_type, "")
      |> assign(:filter_resource_id, "")
      |> assign(:filter_date_from, "")
      |> assign(:filter_date_to, "")
      |> assign(:event_types, [])
      |> assign(:filter_count, 0)
      |> assign(:audit_command, empty_audit_command())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    socket =
      socket
      |> assign(:filter_event_type, params["filter_event_type"] || "")
      |> assign(:filter_actor_type, params["filter_actor_type"] || "")
      |> assign(:filter_actor_id, params["filter_actor_id"] || "")
      |> assign(:filter_resource_type, params["filter_resource_type"] || "")
      |> assign(:filter_resource_id, params["filter_resource_id"] || "")
      |> assign(:filter_date_from, params["filter_date_from"] || "")
      |> assign(:filter_date_to, params["filter_date_to"] || "")
      |> assign_filter_count()
      |> load_event_types()
      |> assign_audit_command()

    {:noreply, init_stream(socket, :events, &fetch_events(socket, &1))}
  end

  @impl true
  def handle_event("filter", attrs, socket) do
    socket =
      socket
      |> assign(:filter_event_type, attrs["filter_event_type"] || "")
      |> assign(:filter_actor_type, attrs["filter_actor_type"] || "")
      |> assign(:filter_actor_id, attrs["filter_actor_id"] || "")
      |> assign(:filter_resource_type, attrs["filter_resource_type"] || "")
      |> assign(:filter_resource_id, attrs["filter_resource_id"] || "")
      |> assign(:filter_date_from, attrs["filter_date_from"] || "")
      |> assign(:filter_date_to, attrs["filter_date_to"] || "")

    {:noreply, push_patch(socket, to: build_url(socket))}
  end

  def handle_event("clear_filters", _, socket) do
    socket =
      socket
      |> assign(:filter_event_type, "")
      |> assign(:filter_actor_type, "")
      |> assign(:filter_actor_id, "")
      |> assign(:filter_resource_type, "")
      |> assign(:filter_resource_id, "")
      |> assign(:filter_date_from, "")
      |> assign(:filter_date_to, "")
      |> push_event("datepicker:reset", %{})

    {:noreply, push_patch(socket, to: ~p"/settings/audit")}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :events, &fetch_events(socket, &1))}
  end

  # Filter forms filter live via phx-change; phx-submit="prevent" only suppresses
  # a full-page submit on Enter, so this is intentionally a no-op.
  def handle_event("prevent", _params, socket), do: {:noreply, socket}

  defp fetch_events(socket, cursor) do
    AuditTrail.list_company_events_page(
      socket.assigns.company_id,
      [after: cursor] ++ filter_opts(socket)
    )
  end

  defp assign_audit_command(socket) do
    snapshot = AuditTrail.company_audit_snapshot(socket.assigns.company_id, filter_opts(socket))
    assign(socket, :audit_command, build_audit_command(snapshot, filters_active?(socket)))
  end

  # The Filter menu's count: how many filters the URL sets.
  defp assign_filter_count(socket) do
    a = socket.assigns

    count =
      Enum.count(
        [
          a.filter_event_type,
          a.filter_actor_type,
          a.filter_actor_id,
          a.filter_resource_type,
          a.filter_resource_id,
          a.filter_date_from,
          a.filter_date_to
        ],
        &(&1 not in [nil, ""])
      )

    assign(socket, :filter_count, count)
  end

  defp filters_active?(socket) do
    a = socket.assigns

    a.filter_event_type not in [nil, ""] or a.filter_actor_type not in [nil, ""] or
      a.filter_actor_id not in [nil, ""] or a.filter_resource_type not in [nil, ""] or
      a.filter_resource_id not in [nil, ""] or a.filter_date_from not in [nil, ""] or
      a.filter_date_to not in [nil, ""]
  end

  defp empty_audit_command do
    %{
      tone: :idle,
      badge: "Empty",
      heading: "No audit events have been recorded yet",
      detail: "Events appear here as work gets created, approved, and run.",
      focus_label: nil,
      focus_detail: nil,
      actor_summary: nil,
      action_path: ~p"/settings/policies",
      action_label: "Review policies",
      metrics: audit_metrics(0, %{})
    }
  end

  defp build_audit_command(%{total: 0, by_event_type: by_event_type}, true) do
    %{
      empty_audit_command()
      | tone: :filtered,
        badge: "Filtered",
        heading: "No audit events match this view",
        detail: "Clear or loosen filters to return to the full governance trail.",
        action_path: ~p"/settings/audit",
        action_label: "Clear filters",
        metrics: audit_metrics(0, by_event_type)
    }
  end

  defp build_audit_command(%{total: 0, by_event_type: by_event_type}, false) do
    %{empty_audit_command() | metrics: audit_metrics(0, by_event_type)}
  end

  defp build_audit_command(
         %{
           total: total,
           by_event_type: by_event_type,
           by_actor_type: by_actor_type,
           latest: latest
         },
         _filtered?
       ) do
    counts = audit_counts(by_event_type)
    focus = audit_focus(latest)

    command =
      cond do
        Map.get(by_event_type, "decision_reversed", 0) > 0 ->
          %{
            tone: :danger,
            badge: "Reversal",
            heading: "Review reversed governance decisions",
            detail:
              "A decision was reversed. Confirm the reason, downstream work impact, and whether follow-up approvals are needed.",
            action_path: ~p"/reviews",
            action_label: "Open reviews"
          }

        Map.get(by_event_type, "agent_terminated", 0) > 0 ->
          %{
            tone: :danger,
            badge: "Agent",
            heading: "Audit terminated agent activity",
            detail:
              "An agent was terminated. Check ownership gaps, paused work, and whether credentials or execution policies should be tightened.",
            action_path: ~p"/agents",
            action_label: "Open agents"
          }

        counts.governance > 0 ->
          %{
            tone: :review,
            badge: "Governance",
            heading: "Review governance events before closing work",
            detail:
              "Approvals or decisions changed the audit trail. Confirm the board record before treating dependent work as settled.",
            action_path: ~p"/reviews",
            action_label: "Open reviews"
          }

        counts.runtime > 0 ->
          %{
            tone: :attention,
            badge: "Runtime",
            heading: "Inspect runtime audit evidence",
            detail:
              "Orchestrator sessions or tool calls were recorded. Use Operations and tool traces to verify what actually ran.",
            action_path: ~p"/operations#runtime-launch-checklist",
            action_label: "Open operations"
          }

        counts.budget > 0 ->
          %{
            tone: :attention,
            badge: "Budget",
            heading: "Review budget policy changes",
            detail:
              "Budget thresholds changed. Confirm spend controls still match the company’s autonomy level.",
            action_path: ~p"/costs",
            action_label: "Open Spending"
          }

        true ->
          %{
            tone: :healthy,
            badge: "Audit-ready",
            heading: "Audit trail is recording governance-relevant events",
            detail:
              "Events are scoped to this company and can be filtered by actor, resource, event type, and date.",
            action_path: ~p"/settings/audit#audit-events",
            action_label: "Review trail"
          }
      end

    Map.merge(command, %{
      focus_label: focus.label,
      focus_detail: focus.detail,
      actor_summary: actor_summary(by_actor_type),
      metrics: audit_metrics(total, by_event_type)
    })
  end

  defp audit_metric_total(%{metrics: [%{value: total} | _]}), do: total
  defp audit_metric_total(_command), do: 0

  # One strip of at most four cells (v7 P7); the total stays first (audit_metric_total/1).
  defp audit_metrics(total, by_event_type) do
    counts = audit_counts(by_event_type)

    [
      %{label: "Total", value: total},
      %{label: "Governance", value: counts.governance},
      %{label: "Runtime", value: counts.runtime},
      %{label: "Agents", value: counts.agent}
    ]
  end

  defp audit_counts(by_event_type) do
    Enum.reduce(
      by_event_type,
      %{governance: 0, runtime: 0, agent: 0, budget: 0, issue: 0, evidence: 0},
      fn {event_type, count}, acc ->
        Map.update!(acc, audit_category(event_type), &(&1 + count))
      end
    )
  end

  defp audit_category(event_type) when event_type in @governance_events, do: :governance
  defp audit_category(event_type) when event_type in @runtime_events, do: :runtime
  defp audit_category(event_type) when event_type in @agent_events, do: :agent
  defp audit_category(event_type) when event_type in @budget_events, do: :budget
  defp audit_category(event_type) when event_type in @issue_events, do: :issue
  defp audit_category(event_type) when event_type in @evidence_events, do: :evidence
  defp audit_category(_event_type), do: :evidence

  defp audit_focus(nil), do: %{label: nil, detail: nil}

  defp audit_focus(event) do
    label =
      [format_event_type(event.event_type), format_resource(event)]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" · ")

    detail = "#{format_actor_type(event.actor_type)} #{String.slice(event.actor_id || "", 0, 8)}"

    %{label: label, detail: detail}
  end

  defp format_resource(%{resource_type: nil}), do: nil

  defp format_resource(%{resource_type: type, resource_id: nil}),
    do: String.replace(type, "_", " ")

  defp format_resource(%{resource_type: type, resource_id: id}),
    do: "#{String.replace(type, "_", " ")} #{String.slice(id, 0, 8)}"

  defp actor_summary(by_actor_type) do
    by_actor_type
    |> Enum.sort_by(fn {_actor, count} -> count end, :desc)
    |> Enum.map(fn {actor, count} -> "#{format_actor_type(actor)} #{count}" end)
    |> Enum.take(3)
    |> Enum.join(" · ")
  end

  defp filter_opts(socket) do
    a = socket.assigns

    []
    |> maybe_opt(:event_type, a.filter_event_type)
    |> maybe_opt(:actor_type, a.filter_actor_type)
    |> maybe_opt(:actor_id, a.filter_actor_id)
    |> maybe_opt(:resource_type, a.filter_resource_type)
    |> maybe_opt(:resource_id, a.filter_resource_id)
    |> maybe_date_opt(:start_date, a.filter_date_from, ~T[00:00:00])
    |> maybe_date_opt(:end_date, a.filter_date_to, ~T[23:59:59])
  end

  defp maybe_opt(opts, _key, value) when value in [nil, ""], do: opts
  defp maybe_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_date_opt(opts, _key, value, _time) when value in [nil, ""], do: opts

  defp maybe_date_opt(opts, key, value, time) do
    case Date.from_iso8601(value) do
      {:ok, date} -> Keyword.put(opts, key, DateTime.new!(date, time))
      _ -> opts
    end
  end

  defp load_event_types(socket) do
    event_types = AuditTrail.list_event_types(socket.assigns.company_id)
    assign(socket, :event_types, event_types)
  end

  defp build_url(socket) do
    a = socket.assigns

    query =
      %{
        filter_event_type: a.filter_event_type,
        filter_actor_type: a.filter_actor_type,
        filter_actor_id: a.filter_actor_id,
        filter_resource_type: a.filter_resource_type,
        filter_resource_id: a.filter_resource_id,
        filter_date_from: a.filter_date_from,
        filter_date_to: a.filter_date_to
      }
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    ~p"/settings/audit?#{query}"
  end

  defp get_current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  # Formatting functions. Visible words say "task" for the issue event types (v7 §1.2).
  def format_event_type(type),
    do: type |> String.replace("_", " ") |> String.replace("issue", "task") |> String.capitalize()

  def format_actor_type(type), do: String.capitalize(type)

  # "Task created"; the resource is appended only when the event's words do not name it.
  defp event_title(%{event_type: type, resource_type: resource_type}) do
    title = format_event_type(type)
    resource = resource_words(resource_type)

    if resource == "" or String.contains?(String.downcase(title), resource),
      do: title,
      else: "#{title} · #{resource}"
  end

  defp resource_words(nil), do: ""

  defp resource_words(type),
    do: type |> String.replace("_", " ") |> String.replace("issue", "task")

  def format_payload(nil), do: "{}"

  def format_payload(payload) when is_map(payload) do
    payload
    |> Jason.encode!(pretty: true)
  end

  def format_payload(_), do: ""

  # The row's title already names the event, so the summary does not repeat it.
  def payload_summary(event), do: "Payload · #{payload_key_summary(event.payload)}"

  defp payload_key_summary(payload) when is_map(payload) do
    keys =
      payload
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.sort()

    case keys do
      [] ->
        "no keys"

      [key] ->
        "1 key: #{key}"

      keys ->
        visible = Enum.take(keys, 3)
        suffix = if length(keys) > 3, do: " +#{length(keys) - 3}", else: ""
        "#{length(keys)} keys: #{Enum.join(visible, ", ")}#{suffix}"
    end
  end

  defp payload_key_summary(_payload), do: "unstructured"

  # Blocks, stops and terminations read as problems (.kt.p with i-stop).
  @problem_events ~w(issue_blocked agent_terminated company_runtime_stopped)

  defp problem_event?(event_type), do: event_type in @problem_events

  defp audit_icon(event_type) when event_type in @problem_events, do: "i-stop"

  defp audit_icon(event_type) do
    case audit_category(event_type) do
      :governance -> "i-shield"
      :runtime -> "i-term"
      :agent -> "i-team"
      :budget -> "i-spend"
      :issue -> "i-tasks"
      :evidence -> "i-doc-check"
    end
  end
end
