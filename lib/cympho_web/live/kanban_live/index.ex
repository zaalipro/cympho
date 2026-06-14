defmodule CymphoWeb.KanbanLive.Index do
  use CymphoWeb, :live_view
  import CymphoWeb.KanbanLive.Components
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.AgentHeartbeat
  alias Cympho.HeartbeatEngine
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Projects
  alias Cympho.RuntimePreflight

  @status_columns [:backlog, :todo, :in_progress, :in_review, :blocked, :done, :cancelled]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Cympho.Agents.subscribe(socket.assigns.current_company.id)
      CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)

      Phoenix.PubSub.subscribe(
        Cympho.PubSub,
        "agent_heartbeats:#{socket.assigns.current_company.id}"
      )
    end

    company_id = current_company_id(socket)

    projects =
      if company_id,
        do: Projects.list_projects_by_company(company_id),
        else: []

    issues = list_company_issues(company_id)
    agent_heartbeat_states = load_heartbeat_states(issues)
    pending_wakes = load_pending_wakes(issues)
    runtime_enabled? = Dispatcher.enabled?()

    socket =
      socket
      |> assign(:issues, issues)
      |> assign(:agent_heartbeat_states, agent_heartbeat_states)
      |> assign(:pending_wakes, pending_wakes)
      |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, runtime_enabled?))
      |> assign(:projects, projects)
      |> assign(:runtime_enabled?, runtime_enabled?)
      |> assign(
        :agents,
        if(company_id,
          do: Cympho.Agents.list_agents_by_company(company_id),
          else: []
        )
      )
      |> assign(:collapsed_columns, MapSet.new())
      |> assign(:swimlane_mode, false)
      |> assign(:digest_density, "detailed")
      |> assign(:filter_assignee_id, nil)
      |> assign(:filter_priority, nil)
      |> assign(:filter_search, "")
      |> assign(:editing_card_id, nil)
      |> assign(:card_action_open, nil)
      |> assign(:blocked_transition, nil)

    {:ok, socket}
  end

  defp load_pending_wakes(issues) do
    issues
    |> Enum.map(& &1.id)
    |> Cympho.Wakes.most_recent_pending_for_issues()
  end

  defp load_heartbeat_states(issues) do
    agent_ids =
      issues
      |> Enum.map(fn issue -> issue.assignee end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(& &1.id)

    results = AgentHeartbeat.get_states(agent_ids)

    Map.new(agent_ids, fn id ->
      case Map.get(results, id) do
        {:ok, state} ->
          {id, state}

        _ ->
          {id,
           %{
             agent_id: id,
             status: :offline,
             current_issue_id: nil,
             eta_ms: nil
           }}
      end
    end)
  end

  def get_heartbeat_state(agent_heartbeat_states, agent_id) do
    Map.get(agent_heartbeat_states, agent_id, %{
      status: :offline,
      current_issue_id: nil,
      eta_ms: nil
    })
  end

  @impl true
  def handle_params(params, _url, socket) do
    project_id = params["project_id"]
    digest_density = normalize_digest_density(params["density"])

    selected_project =
      case {project_id, socket.assigns[:current_company]} do
        {nil, _} ->
          nil

        {id, %{id: company_id}} ->
          case Projects.get_company_project(company_id, id) do
            {:ok, project} -> project
            {:error, _} -> nil
          end

        _ ->
          nil
      end

    socket =
      socket
      |> assign(:selected_project_id, project_id)
      |> assign(:selected_project, selected_project)
      |> assign(:digest_density, digest_density)
      |> assign(:page_title, "Kanban Board")
      |> apply_project_filter(project_id)

    {:noreply, socket}
  end

  defp apply_project_filter(socket, nil) do
    issues = list_company_issues(current_company_id(socket))

    socket
    |> assign(:issues, issues)
    |> assign(:pending_wakes, load_pending_wakes(issues))
    |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))
  end

  defp apply_project_filter(socket, project_id) do
    issues =
      case current_company_id(socket) do
        nil ->
          []

        company_id ->
          %{company_id: company_id, project_id: project_id}
          |> Issues.list_issues()
      end

    socket
    |> assign(:issues, issues)
    |> assign(:pending_wakes, load_pending_wakes(issues))
    |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))
  end

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "issue_update"}, socket) do
    {:noreply, apply_project_filter(socket, socket.assigns[:selected_project_id])}
  end

  def handle_info({:issue_created, issue}, socket) do
    issues = [issue | socket.assigns.issues]

    {:noreply,
     socket
     |> assign(:issues, issues)
     |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))}
  end

  def handle_info({:issue_updated, updated_issue}, socket) do
    issues =
      Enum.map(socket.assigns.issues, fn issue ->
        if issue.id == updated_issue.id, do: updated_issue, else: issue
      end)

    {:noreply,
     socket
     |> assign(:issues, issues)
     |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))}
  end

  def handle_info({:issue_deleted, deleted_id}, socket) do
    issues = Enum.filter(socket.assigns.issues, fn issue -> issue.id != deleted_id end)

    {:noreply,
     socket
     |> assign(:issues, issues)
     |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))}
  end

  def handle_info({:agent_updated, updated_agent}, socket) do
    issues =
      Enum.map(socket.assigns.issues, fn issue ->
        if issue.assignee && issue.assignee.id == updated_agent.id do
          %{issue | assignee: updated_agent}
        else
          issue
        end
      end)

    {:noreply,
     socket
     |> assign(:issues, issues)
     |> assign(:launch_readiness_by_issue, launch_readiness_by_issue(issues, socket))}
  end

  def handle_info({:agent_heartbeat_updated, agent_id, heartbeat_state}, socket) do
    socket =
      if heartbeat_state.status in [:offline, :idle] do
        agent = Enum.find(socket.assigns.agents, &(&1.id == agent_id))
        name = if agent, do: agent.name, else: "Agent"

        push_event(socket, "toast", %{
          message: "#{name} went #{heartbeat_state.status}",
          type: "warning",
          key: "agent_#{agent_id}_#{heartbeat_state.status}"
        })
      else
        socket
      end

    {:noreply,
     update(socket, :agent_heartbeat_states, fn states ->
       Map.put(states, agent_id, heartbeat_state)
     end)}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    socket =
      case payload do
        %{new_status: "completed", agent_id: aid, issue_id: iid} ->
          a = Enum.find(socket.assigns.agents, &(&1.id == aid))

          push_event(socket, "toast", %{
            message: "#{if a, do: a.name, else: "Agent"} completed work on #{iid}",
            type: "success",
            key: "run_#{iid}_completed"
          })

        %{new_status: "failed", agent_id: aid, issue_id: iid} ->
          a = Enum.find(socket.assigns.agents, &(&1.id == aid))

          push_event(socket, "toast", %{
            message: "#{if a, do: a.name, else: "Agent"} failed on #{iid}",
            type: "error",
            key: "run_#{iid}_failed"
          })

        _ ->
          socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("transition_issue", %{"id" => id, "to_status" => to_status_string}, socket) do
    to_status = try_string_to_status(to_status_string)

    if is_nil(to_status) do
      {:noreply, socket}
    else
      case get_scoped_issue(socket, id) do
        {:ok, issue} ->
          from_status = issue.status

          # Optimistic: update local assigns before the DB write so the server's
          # render matches the SortableJS-moved DOM. On rollback we push the
          # original status back to JS and shake the card.
          socket = update_local_status(socket, id, to_status)

          case Issues.transition_issue_with_review_gates(issue, to_status) do
            {:ok, _updated_issue} ->
              {:noreply,
               socket
               |> assign(:blocked_transition, nil)
               |> push_event("kanban:confirm", %{issue_id: id})}

            {:error, reason} ->
              message = transition_error_message(reason, from_status, to_status)
              blocker = transition_blocker(issue, reason, from_status, to_status, message)

              {:noreply,
               socket
               |> assign(:blocked_transition, blocker)
               |> rollback_transition(id, to_status, from_status, message)}
          end

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Issue not found")}
      end
    end
  end

  def handle_event("dismiss_transition_blocker", _params, socket) do
    {:noreply, assign(socket, :blocked_transition, nil)}
  end

  def handle_event("toggle_column", %{"status" => status_str}, socket) do
    status = String.to_existing_atom(status_str)

    {:noreply,
     update(socket, :collapsed_columns, fn collapsed ->
       if MapSet.member?(collapsed, status) do
         MapSet.delete(collapsed, status)
       else
         MapSet.put(collapsed, status)
       end
     end)}
  end

  def handle_event("toggle_swimlanes", _params, socket) do
    {:noreply, update(socket, :swimlane_mode, fn mode -> not mode end)}
  end

  def handle_event("filter_project", %{"project_id" => project_id}, socket) do
    if project_id == "" do
      {:noreply, push_patch(socket, to: kanban_url(nil, socket.assigns.digest_density))}
    else
      {:noreply, push_patch(socket, to: kanban_url(project_id, socket.assigns.digest_density))}
    end
  end

  def handle_event("combobox_project", %{"selected" => nil}, socket) do
    {:noreply, push_patch(socket, to: kanban_url(nil, socket.assigns.digest_density))}
  end

  def handle_event("combobox_project", %{"selected" => project_id}, socket)
      when is_binary(project_id) do
    {:noreply, push_patch(socket, to: kanban_url(project_id, socket.assigns.digest_density))}
  end

  def handle_event("filter_assignee", %{"assignee_id" => assignee_id}, socket) do
    {:noreply,
     assign(socket, :filter_assignee_id, if(assignee_id == "", do: nil, else: assignee_id))}
  end

  def handle_event("combobox_assignee", %{"selected" => selected}, socket) do
    {:noreply, assign(socket, :filter_assignee_id, selected)}
  end

  def handle_event("filter_priority", %{"priority" => priority}, socket) do
    {:noreply,
     assign(
       socket,
       :filter_priority,
       if(priority == "", do: nil, else: String.to_existing_atom(priority))
     )}
  end

  def handle_event("combobox_priority", %{"selected" => nil}, socket) do
    {:noreply, assign(socket, :filter_priority, nil)}
  end

  def handle_event("combobox_priority", %{"selected" => priority}, socket)
      when is_binary(priority) do
    {:noreply, assign(socket, :filter_priority, String.to_existing_atom(priority))}
  end

  def handle_event("filter_search", %{"query" => query}, socket) do
    {:noreply, assign(socket, :filter_search, query)}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:filter_assignee_id, nil)
     |> assign(:filter_priority, nil)
     |> assign(:filter_search, "")}
  end

  def handle_event("cancel_comment", _params, socket) do
    {:noreply, assign(socket, :editing_card_id, nil)}
  end

  def handle_event("submit_comment", %{"issue-id" => issue_id, "comment" => comment}, socket) do
    case Cympho.Comments.create_comment(%{issue_id: issue_id, body: comment}) do
      {:ok, _} -> {:noreply, assign(socket, :editing_card_id, nil)}
      {:error, _} -> {:noreply, socket}
    end
  end

  defp update_local_status(socket, issue_id, new_status) do
    update(socket, :issues, fn issues ->
      Enum.map(issues, fn
        %{id: ^issue_id} = issue -> %{issue | status: new_status}
        issue -> issue
      end)
    end)
  end

  defp rollback_transition(socket, issue_id, attempted_status, original_status, message) do
    socket
    |> update_local_status(issue_id, original_status)
    |> put_flash(:error, message)
    |> push_event("kanban:rollback", %{
      issue_id: issue_id,
      from_status: to_string(attempted_status),
      to_status: to_string(original_status)
    })
    |> push_event("shake_card", %{issue_id: issue_id})
  end

  defp transition_error_message(:invalid_transition, from_status, to_status) do
    "Invalid status transition from #{from_status} to #{to_status}"
  end

  defp transition_error_message(:blocked_by_active_issues, _from_status, _to_status) do
    "Cannot complete — issue is blocked by active issues"
  end

  defp transition_error_message(
         {:review_gates_blocked, %{message: message}},
         _from_status,
         _to_status
       ) do
    message
  end

  defp transition_error_message(other, _from_status, _to_status) do
    "Could not move issue: #{inspect(other)}"
  end

  defp transition_blocker(
         issue,
         {:review_gates_blocked, %{blockers: blockers}},
         from_status,
         to_status,
         message
       ) do
    %{
      issue_id: issue.id,
      issue_title: issue.title,
      issue_identifier: issue.identifier || fallback_identifier(issue),
      from_status: from_status,
      to_status: to_status,
      message: message,
      blockers: blockers,
      actions: transition_blocker_actions(issue, blockers)
    }
  end

  defp transition_blocker(issue, reason, from_status, to_status, message) do
    %{
      issue_id: issue.id,
      issue_title: issue.title,
      issue_identifier: issue.identifier || fallback_identifier(issue),
      from_status: from_status,
      to_status: to_status,
      message: message,
      blockers: [
        %{
          key: reason,
          label: transition_error_label(reason),
          prompt: transition_error_prompt(reason)
        }
      ],
      actions: [%{label: "Open issue", path: "/issues/#{issue.id}"}]
    }
  end

  defp transition_blocker_actions(%Issue{} = issue, blockers) do
    issue_path = "/issues/#{issue.id}"

    if pre_runtime_transition_blocker?(issue, blockers) do
      [
        %{label: "Open issue", path: issue_path},
        %{label: "Open launch checklist", path: "/operations#runtime-launch-checklist"},
        %{label: "Open issue preflight", path: "#{issue_path}#issue-agent-panel"}
      ]
    else
      [
        %{label: "Open issue", path: issue_path}
        | blockers
          |> Enum.flat_map(&blocker_action(issue_path, &1))
          |> Enum.uniq_by(& &1.label)
      ]
    end
  end

  defp pre_runtime_transition_blocker?(%Issue{status: status} = issue, blockers)
       when status in [:todo, "todo"] do
    runtime_blocked? =
      Enum.any?(blockers, fn
        %{key: :runtime_verification} -> true
        _ -> false
      end)

    runtime_blocked? and Enum.empty?(HeartbeatEngine.list_runs_for_issue(issue.id))
  end

  defp pre_runtime_transition_blocker?(_issue, _blockers), do: false

  defp blocker_action(issue_path, %{key: :runtime_verification}) do
    [
      %{
        label: "Start verification",
        path: gate_path(issue_path, "verification", "issue-agent-panel")
      }
    ]
  end

  defp blocker_action(issue_path, %{key: :agent_note}) do
    [
      %{
        label: "Add completion note",
        path: gate_path(issue_path, "delivery_note", "issue-comments")
      }
    ]
  end

  defp blocker_action(issue_path, %{key: :owner_summary}) do
    [%{label: "Add owner update", path: gate_path(issue_path, "owner_update", "issue-comments")}]
  end

  defp blocker_action(issue_path, %{key: :work_product}) do
    [
      %{
        label: "Attach work product",
        path: gate_path(issue_path, "work_product", "issue-work-product-form")
      }
    ]
  end

  defp blocker_action(issue_path, %{key: :child_work}) do
    [%{label: "Open sub-issues", path: "#{issue_path}#issue-sub-issues"}]
  end

  defp blocker_action(issue_path, %{key: :review_decision}) do
    [
      %{
        label: "Add review comment",
        path: gate_path(issue_path, "review_comment", "issue-comments")
      }
    ]
  end

  defp blocker_action(issue_path, %{key: :code_reference}) do
    [%{label: "Set PR link", path: gate_path(issue_path, "code_reference", "issue-github-pr")}]
  end

  defp blocker_action(_issue_path, _blocker), do: []

  defp gate_path(issue_path, gate, anchor), do: "#{issue_path}?gate=#{gate}##{anchor}"

  defp transition_error_label(:invalid_transition), do: "Invalid workflow move"
  defp transition_error_label(:blocked_by_active_issues), do: "Active dependency"
  defp transition_error_label(_), do: "Move blocked"

  defp transition_error_prompt(:invalid_transition) do
    "Use one of the card's available next-status buttons instead."
  end

  defp transition_error_prompt(:blocked_by_active_issues) do
    "Finish or cancel the active blocker before closing this issue."
  end

  defp transition_error_prompt(_), do: "Open the issue and resolve the blocker before retrying."

  defp fallback_identifier(issue), do: "CYM-" <> String.slice(issue.id, 0, 4)

  defp try_string_to_status(string) do
    if Enum.member?(Issue.status_options(), String.to_existing_atom(string)) do
      String.to_existing_atom(string)
    else
      nil
    end
  rescue
    ArgumentError -> nil
  end

  def issues_for_status(issues, status), do: Enum.filter(issues, &(&1.status == status))

  def valid_next_statuses(:backlog), do: [:todo, :cancelled]
  def valid_next_statuses(:todo), do: [:in_progress, :blocked, :cancelled]
  def valid_next_statuses(:in_progress), do: [:in_review, :blocked, :done, :cancelled]
  def valid_next_statuses(:in_review), do: [:done, :in_progress, :cancelled]
  def valid_next_statuses(:blocked), do: [:todo, :in_progress, :cancelled]
  def valid_next_statuses(:done), do: []
  def valid_next_statuses(:cancelled), do: []

  def status_label(:backlog), do: "Backlog"
  def status_label(:todo), do: "To Do"
  def status_label(:in_progress), do: "In Progress"
  def status_label(:in_review), do: "In Review"
  def status_label(:done), do: "Done"
  def status_label(:blocked), do: "Blocked"
  def status_label(:cancelled), do: "Cancelled"

  def status_columns, do: @status_columns

  defp launch_readiness_by_issue(issues, socket) when is_list(issues) and is_map(socket) do
    launch_readiness_by_issue(issues, socket.assigns[:runtime_enabled?] || false)
  end

  defp launch_readiness_by_issue(issues, runtime_enabled?) when is_list(issues) do
    issues
    |> Enum.filter(&launch_readiness_issue?/1)
    |> Enum.map(fn issue -> {issue.id, launch_readiness(issue, runtime_enabled?)} end)
    |> Map.new()
  end

  defp launch_readiness_issue?(%{status: status})
       when status in [:todo, :in_review, :blocked, "todo", "in_review", "blocked"],
       do: true

  defp launch_readiness_issue?(_issue), do: false

  defp launch_readiness(issue, runtime_enabled?) do
    preflight = RuntimePreflight.for_issue(issue, autonomy_enabled?: runtime_enabled?)

    %{
      status: preflight.status,
      label: launch_readiness_label(preflight),
      target: launch_readiness_target(preflight),
      summary: preflight.summary,
      path: "/issues/#{issue.id}#issue-agent-panel",
      class: launch_readiness_class(preflight.status)
    }
  end

  defp launch_readiness_label(%{status: :ready}), do: "Ready"
  defp launch_readiness_label(%{status: :review_mode}), do: "Review mode"
  defp launch_readiness_label(%{status: :attention}), do: "Needs setup"
  defp launch_readiness_label(%{status: :blocked, agent_id: nil}), do: "No agent"
  defp launch_readiness_label(%{status: :blocked}), do: "Blocked"
  defp launch_readiness_label(%{label: label}) when is_binary(label), do: label
  defp launch_readiness_label(_preflight), do: "Check"

  defp launch_readiness_target(%{agent_name: name}) when is_binary(name) and name != "",
    do: name

  defp launch_readiness_target(%{agent_role: role}) when role not in [nil, ""],
    do: role |> to_string() |> String.replace("_", " ") |> String.capitalize()

  defp launch_readiness_target(_preflight), do: "Route unknown"

  defp launch_readiness_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp launch_readiness_class(:review_mode),
    do: "border-sky-500/25 bg-sky-500/10 text-sky-300"

  defp launch_readiness_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp launch_readiness_class(:blocked),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp launch_readiness_class(_status), do: "border-border bg-panel text-text-secondary"

  def board_flow_metrics(issues) do
    [
      %{
        key: :blocked,
        label: "Blocked",
        count: length(blocked_issues(issues)),
        detail: "Needs operator decision",
        class: "border-brand/25 bg-brand/10 text-brand"
      },
      %{
        key: :review,
        label: "Review",
        count: length(in_review_issues(issues)),
        detail: "Awaiting acceptance",
        class: "border-sky-500/25 bg-sky-500/10 text-sky-300"
      },
      %{
        key: :active,
        label: "Active",
        count: length(in_progress_issues(issues)),
        detail: "Runtime or manual work moving",
        class: "border-blue-500/25 bg-blue-500/10 text-blue-300"
      },
      %{
        key: :ready,
        label: "Ready",
        count: length(todo_issues(issues)),
        detail: "Queued for next dispatch",
        class: "border-amber-500/25 bg-amber-500/10 text-amber-300"
      }
    ]
  end

  def board_focus_items(issues, pending_wakes) do
    issues
    |> Enum.reject(&terminal_issue?/1)
    |> Enum.map(&board_focus_item(&1, pending_wakes))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn item ->
      {item.rank, priority_rank(item.issue.priority), DateTime.to_unix(item.issue.inserted_at)}
    end)
    |> Enum.take(3)
  end

  defp board_focus_item(%{status: :blocked} = issue, _pending_wakes) do
    board_focus_item(
      issue,
      0,
      "Unblock",
      "Resolve the blocker before dragging this card forward."
    )
  end

  defp board_focus_item(%{assigned_role: "ceo", assignee_id: nil} = issue, _pending_wakes) do
    board_focus_item(
      issue,
      1,
      "Add CEO",
      "Create or assign the CEO before this owner request can launch."
    )
  end

  defp board_focus_item(%{assignee_id: nil, assigned_role: role} = issue, _pending_wakes)
       when role in [nil, ""] do
    board_focus_item(
      issue,
      2,
      "Assign owner",
      "Pick the agent or role responsible for the next move."
    )
  end

  defp board_focus_item(%{assigned_role: "ceo", status: :todo} = issue, _pending_wakes) do
    board_focus_item(
      issue,
      3,
      "Launch CEO",
      "Start the first CEO turn and require owner update, handoff, or blocker."
    )
  end

  defp board_focus_item(%{status: :in_review} = issue, _pending_wakes) do
    board_focus_item(issue, 4, "Review", "Accept, request changes, or ask for missing evidence.")
  end

  defp board_focus_item(%{status: :in_progress} = issue, pending_wakes) do
    detail =
      if Map.has_key?(pending_wakes, issue.id) do
        "A wake is queued. Watch for evidence before moving the card."
      else
        "Inspect runtime evidence and make sure the card is not stale."
      end

    board_focus_item(issue, 5, "Observe", detail)
  end

  defp board_focus_item(%{status: :todo} = issue, pending_wakes) do
    detail =
      if Map.has_key?(pending_wakes, issue.id) do
        "Wake is queued; watch for the next agent signal."
      else
        "Prioritize this card for dispatch or assign an idle agent."
      end

    board_focus_item(issue, 6, "Dispatch", detail)
  end

  defp board_focus_item(%{status: :backlog} = issue, _pending_wakes) do
    board_focus_item(issue, 7, "Scope", "Clarify the request, then promote it to To Do.")
  end

  defp board_focus_item(_issue, _pending_wakes), do: nil

  defp board_focus_item(issue, rank, action, detail) do
    %{
      issue: issue,
      rank: rank,
      action: action,
      detail: detail,
      identifier: board_issue_identifier(issue),
      path: "/issues/#{issue.id}"
    }
  end

  defp terminal_issue?(%{status: status}), do: status in [:done, :cancelled]

  defp priority_rank(:critical), do: 0
  defp priority_rank(:high), do: 1
  defp priority_rank(:medium), do: 2
  defp priority_rank(:low), do: 3
  defp priority_rank(_), do: 4

  defp board_issue_identifier(%{identifier: identifier})
       when is_binary(identifier) and identifier != "",
       do: identifier

  defp board_issue_identifier(%{issue_number: number}) when is_integer(number),
    do: "CYM-#{number}"

  defp board_issue_identifier(%{id: id}) when is_binary(id), do: "CYM-#{String.slice(id, 0, 4)}"
  defp board_issue_identifier(_issue), do: "CYM"

  def board_focus_action_class("Unblock"), do: "border-brand/25 bg-brand/10 text-brand"

  def board_focus_action_class("Add CEO"),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def board_focus_action_class("Assign owner"),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def board_focus_action_class("Launch CEO"), do: "border-sky-500/25 bg-sky-500/10 text-sky-300"
  def board_focus_action_class("Review"), do: "border-brand/25 bg-brand/10 text-brand"
  def board_focus_action_class("Observe"), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def board_focus_action_class(_action), do: "border-border bg-panel text-text-secondary"

  def kanban_url(project_id, density) do
    query =
      %{
        project_id: project_id,
        density: density
      }
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
      |> Enum.into(%{})

    ~p"/kanban?#{query}"
  end

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "detailed"

  def density_tab_class(current, density) do
    if current == density do
      "bg-brand text-on-primary"
    else
      "text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
    end
  end

  def wip_limit(nil, _status), do: nil

  def wip_limit(project, status) when is_map(project) do
    settings = project.settings || %{}
    wip_limits = Map.get(settings, "wip_limits", %{})
    Map.get(wip_limits, to_string(status))
  end

  def wip_exceeded?(nil, _count), do: false
  def wip_exceeded?(limit, count) when is_integer(limit), do: count > limit
  def wip_exceeded?(_, _), do: false

  def assignee_groups(issues) do
    issues
    |> Enum.group_by(fn issue ->
      if issue.assignee, do: issue.assignee.name, else: "Unassigned"
    end)
    |> Enum.sort_by(fn {name, _} -> name end)
  end

  def active_filter_count(assigns) do
    count = 0
    count = if assigns[:filter_assignee_id], do: count + 1, else: count
    count = if assigns[:filter_priority], do: count + 1, else: count

    count =
      if assigns[:filter_search] != "" and assigns[:filter_search] != nil,
        do: count + 1,
        else: count

    count
  end

  def apply_filters(issues, %{assignee_id: assignee_id, priority: priority, search: search}) do
    issues
    |> filter_by_assignee(assignee_id)
    |> filter_by_priority(priority)
    |> filter_by_search(search)
  end

  defp filter_by_assignee(issues, nil), do: issues
  defp filter_by_assignee(issues, ""), do: issues

  defp filter_by_assignee(issues, assignee_id) do
    Enum.filter(issues, fn issue -> issue.assignee && issue.assignee.id == assignee_id end)
  end

  defp filter_by_priority(issues, nil), do: issues
  defp filter_by_priority(issues, ""), do: issues

  defp filter_by_priority(issues, priority) do
    priority_atom = if is_binary(priority), do: String.to_existing_atom(priority), else: priority
    Enum.filter(issues, fn issue -> issue.priority == priority_atom end)
  end

  defp filter_by_search(issues, ""), do: issues
  defp filter_by_search(issues, nil), do: issues

  defp filter_by_search(issues, search) do
    lower_search = String.downcase(search)

    Enum.filter(issues, fn issue ->
      haystack =
        [
          issue.title,
          issue.identifier,
          issue.assignee && issue.assignee.name,
          to_string(issue.priority)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> String.downcase()

      String.contains?(haystack, lower_search)
    end)
  end

  def backlog_issues(issues), do: issues_for_status(issues, :backlog)
  def todo_issues(issues), do: issues_for_status(issues, :todo)
  def in_progress_issues(issues), do: issues_for_status(issues, :in_progress)
  def in_review_issues(issues), do: issues_for_status(issues, :in_review)
  def done_issues(issues), do: issues_for_status(issues, :done)
  def blocked_issues(issues), do: issues_for_status(issues, :blocked)
  def cancelled_issues(issues), do: issues_for_status(issues, :cancelled)

  defp current_company_id(socket) do
    socket.assigns[:current_company] && socket.assigns.current_company.id
  end

  defp list_company_issues(nil), do: []
  defp list_company_issues(company_id), do: Issues.list_issues(%{company_id: company_id})

  defp get_scoped_issue(socket, id) do
    case current_company_id(socket) do
      nil -> {:error, :not_found}
      company_id -> Issues.get_company_issue(company_id, id)
    end
  end
end
