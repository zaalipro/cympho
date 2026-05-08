defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  use CymphoWeb, :html
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Documents
  alias Cympho.Orchestrator
  alias Cympho.HeartbeatEngine
  alias Cympho.IssueReadStates
  alias Cympho.IssueThreadInteractions
  alias Cympho.WorkProducts
  alias Cympho.ToolCallTraces

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Comments.subscribe(socket.assigns.current_company.id)
      CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)
      Documents.subscribe(socket.assigns.current_company.id)
    end

    # Subscribe to read state updates if user is logged in
    current_user = socket.assigns[:current_user]

    if current_user do
      IssueReadStates.subscribe(current_user.id)
    end

    case get_scoped_issue(socket, id) do
      {:ok, issue} ->
        # Auto-mark as read for the current user
        if current_user do
          IssueReadStates.ensure_read(current_user.id, issue.id)
        end

        comment_changeset = Comments.Comment.changeset(%Comments.Comment{}, %{})
        runs = HeartbeatEngine.list_runs_for_issue(issue.id)
        interactions = IssueThreadInteractions.list_interactions(issue.id)
        work_products = WorkProducts.list_work_products(issue.id)
        child_issues = Issues.list_child_issues(issue.id)
        tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: issue.id)
        timeline = build_timeline(issue, runs, interactions, work_products, tool_call_traces)
        documents = Documents.list_documents(issue.id)

        {:ok,
         assign(socket,
           issue: issue,
           comment_changeset: comment_changeset,
           comment_form: to_form(comment_changeset),
           agents: list_idle_agents(socket),
           all_agents: list_company_agents(socket),
           orchestrator_enabled?: Cympho.Orchestrator.Dispatcher.enabled?(),
           show_agent_panel: false,
           editing: nil,
           assignee_search: "",
           runs: runs,
           interactions: interactions,
           work_products: work_products,
           child_issues: child_issues,
           tool_call_traces: tool_call_traces,
           timeline: timeline,
           scrolled_to_bottom: true,
           expanded_traces: %{},
           documents: documents,
           selected_document: nil,
           show_revisions: false,
           revisions: [],
           selected_revision_diff: nil,
           rollback_blocker: nil
         )}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/issues")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, :show, id) do
    case get_scoped_issue(socket, id) do
      {:ok, issue} ->
        socket
        |> assign(:page_title, issue.title)
        |> assign(:issue, issue)
        |> assign(:child_issues, Issues.list_child_issues(issue.id))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Issue not found")
        |> push_navigate(to: ~p"/issues")
    end
  end

  defp apply_action(socket, nil, id) do
    apply_action(socket, :show, id)
  end

  @impl true
  def handle_event("add_comment", %{"comment" => comment_params}, socket) do
    comment_params = Map.put(comment_params, "issue_id", socket.assigns.issue.id)

    case Comments.create_comment(comment_params) do
      {:ok, _comment} ->
        changeset = Comments.Comment.changeset(%Comments.Comment{}, %{})

        {:noreply,
         assign(socket,
           comment_changeset: changeset,
           comment_form: to_form(changeset)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, comment_changeset: changeset, comment_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    comment = Comments.get_comment!(id)
    _ = Comments.delete_comment(comment)
    {:noreply, socket}
  end

  @impl true
  def handle_event("combobox_status", %{"selected" => status}, socket) when is_binary(status) do
    handle_event("update_status", %{"status" => status}, socket)
  end

  def handle_event("combobox_status", _, socket), do: {:noreply, socket}

  def handle_event("combobox_priority", %{"selected" => priority}, socket)
      when is_binary(priority) do
    handle_event("update_priority", %{"priority" => priority}, socket)
  end

  def handle_event("combobox_priority", _, socket), do: {:noreply, socket}

  def handle_event("combobox_assignee", %{"selected" => nil}, socket) do
    handle_event("unassign_issue", %{}, socket)
  end

  def handle_event("combobox_assignee", %{"selected" => agent_id}, socket)
      when is_binary(agent_id) do
    handle_event("assign_issue", %{"agent_id" => agent_id}, socket)
  end

  @impl true
  def handle_event("update_status", %{"status" => status}, socket) do
    status_atoms = %{
      "backlog" => :backlog,
      "todo" => :todo,
      "in_progress" => :in_progress,
      "in_review" => :in_review,
      "done" => :done,
      "blocked" => :blocked,
      "cancelled" => :cancelled
    }

    case Map.fetch(status_atoms, status) do
      {:ok, status_atom} ->
        case Issues.transition_issue(socket.assigns.issue, status_atom) do
          {:ok, issue} ->
            {:noreply,
             socket
             |> assign(issue: issue)
             |> put_flash(:info, "Status updated to #{status}")}

          {:error, :invalid_transition} ->
            {:noreply, put_flash(socket, :error, "Invalid transition")}

          {:error, :blocked_by_active_issues} ->
            {:noreply, put_flash(socket, :error, "Issue is blocked by active issues")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid status")}
    end
  end

  @impl true
  def handle_event("update_priority", %{"priority" => priority}, socket) do
    priority_atom = try_string_to_priority(priority)

    case priority_atom do
      nil ->
        {:noreply, put_flash(socket, :error, "Invalid priority")}

      atom ->
        case Issues.update_issue(socket.assigns.issue, %{priority: atom}) do
          {:ok, issue} ->
            {:noreply, socket |> assign(issue: issue) |> put_flash(:info, "Priority updated")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update priority")}
        end
    end
  end

  @impl true
  def handle_event("start_editing", %{"field" => field}, socket) do
    {:noreply, assign(socket, :editing, field)}
  end

  @impl true
  def handle_event("cancel_editing", _params, socket) do
    {:noreply, assign(socket, :editing, nil)}
  end

  @impl true
  def handle_event("save_title", %{"title" => title}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{title: title}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue, editing: nil)
         |> put_flash(:info, "Title updated")}

      {:error, _} ->
        message =
          if String.trim(title) == "" do
            "Title cannot be empty"
          else
            "Failed to update title"
          end

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("save_description", %{"description" => description}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{description: description}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue, editing: nil)
         |> put_flash(:info, "Description updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update description")}
    end
  end

  @impl true
  def handle_event("update_github_pr_number", %{"github_pr_number" => raw}, socket) do
    pr_number = parse_pr_number(raw)
    attrs = %{github_pr_number: pr_number, github_pr_url: nil}

    case Issues.update_issue(socket.assigns.issue, attrs) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update PR number")}
    end
  end

  @impl true
  def handle_event("clear_github_pr_number", _params, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_number: nil, github_pr_url: nil}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to clear PR")}
    end
  end

  @impl true
  def handle_event("search_assignee", %{"q" => q}, socket) do
    {:noreply, assign(socket, assignee_search: q)}
  end

  def handle_event("search_assignee", %{"value" => q}, socket) do
    {:noreply, assign(socket, assignee_search: q)}
  end

  @impl true
  def handle_event("assign_issue", %{"agent_id" => agent_id}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{assignee_id: agent_id}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue, assignee_search: "")
         |> put_flash(:info, "Assignee updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to assign issue")}
    end
  end

  @impl true
  def handle_event("unassign_issue", _params, socket) do
    case Issues.update_issue(socket.assigns.issue, %{assignee_id: nil}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue)
         |> put_flash(:info, "Assignee removed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unassign issue")}
    end
  end

  @impl true
  def handle_event("toggle_agent_panel", _, socket) do
    if socket.assigns.orchestrator_enabled? do
      {:noreply, update(socket, :show_agent_panel, &(!&1))}
    else
      {:noreply, put_flash(socket, :error, "Agent execution is disabled in this runtime")}
    end
  end

  @impl true
  def handle_event("spawn_agent", %{"agent_id" => agent_id}, socket) do
    issue = socket.assigns.issue

    if socket.assigns.orchestrator_enabled? do
      with {:ok, checked_out} <- Issues.checkout_issue(issue, agent_id),
           {:ok, _pid} <- Orchestrator.start_and_run(checked_out, agent_id),
           {:ok, agent} <- Agents.get_agent(agent_id),
           {:ok, _updated_agent} <- Agents.update_agent(agent, %{status: :running}) do
        {:noreply,
         socket
         |> put_flash(:info, "Agent started successfully")
         |> assign(:issue, checked_out)
         |> assign(:show_agent_panel, false)
         |> assign(:agents, list_idle_agents(socket))}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to spawn agent: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Agent execution is disabled in this runtime")}
    end
  end

  @impl true
  def handle_event("release_issue", _params, socket) do
    case Issues.release_issue(socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply, assign(socket, issue: issue)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to release issue: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("resolve_interaction", %{"id" => id, "status" => status}, socket) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: to_string(current_user.id), else: nil

    with {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => String.to_existing_atom(status),
             "resolved_by_user_id" => user_id
           }) do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Invalid state transition")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Interaction not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve interaction")}
    end
  end

  @impl true
  def handle_event(
        "respond_questions",
        %{"_id" => id, "response" => response},
        socket
      ) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: to_string(current_user.id), else: nil

    with {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => :responded,
             "resolved_by_user_id" => user_id,
             "response" => response
           }) do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Invalid state transition")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Interaction not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to respond")}
    end
  end

  @impl true
  def handle_event("toggle_trace", %{"id" => id}, socket) do
    expanded_traces = socket.assigns.expanded_traces
    new_state = Map.put(expanded_traces, id, !Map.get(expanded_traces, id, false))
    {:noreply, assign(socket, :expanded_traces, new_state)}
  end

  @impl true
  def handle_event("show_document_revisions", %{"document_key" => key}, socket) do
    case Documents.get_document_by_key(socket.assigns.issue.id, key) do
      {:ok, document} ->
        revisions = Documents.list_revisions(document.id)

        # Check for plan approval binding blocker
        blocker = check_plan_approval_blocker(key, socket.assigns.issue)

        {:noreply,
         assign(socket,
           selected_document: document,
           show_revisions: true,
           revisions: revisions,
           selected_revision_diff: nil,
           rollback_blocker: blocker
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document not found")}
    end
  end

  @impl true
  def handle_event("hide_revisions", _, socket) do
    {:noreply,
     assign(socket,
       selected_document: nil,
       show_revisions: false,
       revisions: [],
       selected_revision_diff: nil,
       rollback_blocker: nil
     )}
  end

  @impl true
  def handle_event("show_revision_diff", %{"revision_id" => revision_id}, socket) do
    revisions = socket.assigns.revisions

    latest_revision =
      case revisions do
        [first | _] -> first
        [] -> nil
      end

    if latest_revision do
      diff_result = Documents.get_diff(revision_id, latest_revision.id)
      {:noreply, assign(socket, :selected_revision_diff, diff_result)}
    else
      {:noreply, put_flash(socket, :error, "No revisions to compare")}
    end
  end

  @impl true
  def handle_event("hide_revision_diff", _, socket) do
    {:noreply, assign(socket, :selected_revision_diff, nil)}
  end

  @impl true
  def handle_event("restore_revision", %{"revision_id" => revision_id}, socket) do
    if socket.assigns.rollback_blocker do
      {:noreply, put_flash(socket, :error, socket.assigns.rollback_blocker)}
    else
      document = socket.assigns.selected_document

      case Documents.rollback_to_revision(document, revision_id) do
        {:ok, _restored} ->
          # Reload documents and revisions
          documents = Documents.list_documents(socket.assigns.issue.id)
          revisions = Documents.list_revisions(document.id)

          {:noreply,
           socket
           |> put_flash(:info, "Document restored successfully")
           |> assign(
             documents: documents,
             revisions: revisions,
             selected_revision_diff: nil
           )}

        {:error, :pending_approvals} ->
          {:noreply, put_flash(socket, :error, "Cannot restore: issue has pending approvals")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to restore revision")}
      end
    end
  end

  defp parse_pr_number(nil), do: nil
  defp parse_pr_number(""), do: nil

  defp parse_pr_number(raw) when is_binary(raw) do
    raw
    |> String.trim()
    |> String.trim_leading("#")
    |> Integer.parse()
    |> case do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_pr_number(raw) when is_integer(raw) and raw > 0, do: raw
  defp parse_pr_number(_), do: nil

  @impl true
  def handle_info({:issue_updated, updated_issue}, socket) do
    cond do
      socket.assigns.issue.id == updated_issue.id ->
        runs = HeartbeatEngine.list_runs_for_issue(updated_issue.id)

        socket =
          socket
          |> assign(
            issue: updated_issue,
            runs: runs,
            child_issues: Issues.list_child_issues(updated_issue.id)
          )
          |> push_event("toast", %{
            message: "Issue updated by another user",
            type: "info",
            key: "issue_#{updated_issue.id}_updated"
          })

        {:noreply, maybe_rebuild_timeline(socket)}

      updated_issue.parent_id == socket.assigns.issue.id ->
        {:noreply,
         assign(socket, :child_issues, Issues.list_child_issues(socket.assigns.issue.id))}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:issue_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end

  def handle_info({:comment_created, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      socket =
        socket
        |> assign(:issue, updated_issue)
        |> push_event("toast", %{
          message: "New comment added",
          type: "info",
          key: "comment_#{updated_issue.id}_created"
        })

      {:noreply, maybe_rebuild_timeline(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      socket = assign(socket, :issue, updated_issue)
      {:noreply, maybe_rebuild_timeline(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_deleted, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      socket = assign(socket, :issue, updated_issue)
      {:noreply, maybe_rebuild_timeline(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:issue_read_state_updated, _issue_id}, socket) do
    # Refresh the issue to update unread indicators
    case Issues.get_issue(socket.assigns.issue.id) do
      {:ok, issue} ->
        {:noreply, assign(socket, :issue, issue)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:new_comment_on_read_issue, _issue_id, _comment_id}, socket) do
    case Issues.get_issue(socket.assigns.issue.id) do
      {:ok, issue} ->
        {:noreply, assign(socket, :issue, issue)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:interaction_created, interaction}, socket) do
    if socket.assigns.issue.id == interaction.issue_id do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:interaction_updated, interaction}, socket) do
    if socket.assigns.issue.id == interaction.issue_id do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:work_product_created, work_product}, socket) do
    if socket.assigns.issue.id == work_product.issue_id do
      work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          socket.assigns.interactions,
          work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, work_products: work_products, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:work_product_updated, work_product}, socket) do
    if socket.assigns.issue.id == work_product.issue_id do
      work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          socket.assigns.interactions,
          work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, work_products: work_products, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:work_product_deleted, issue_id}, socket) do
    if socket.assigns.issue.id == issue_id do
      work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          socket.assigns.interactions,
          work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, work_products: work_products, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:tool_call_trace_created, trace}, socket) do
    if socket.assigns.issue.id == trace.issue_id do
      tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          socket.assigns.interactions,
          socket.assigns.work_products,
          tool_call_traces
        )

      {:noreply, assign(socket, tool_call_traces: tool_call_traces, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_started, session_id}, socket) do
    {:noreply, assign(socket, :agent_session_id, session_id)}
  end

  def handle_info({:turn_completed, _session_id, _result}, socket) do
    {:noreply, socket}
  end

  def handle_info({:turn_ended_with_error, _session_id, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Agent error: #{inspect(reason)}")}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    issue_id = socket.assigns.issue.id

    if payload[:issue_id] == issue_id do
      {message, type} =
        case payload do
          %{new_status: "running"} -> {"Run started", "info"}
          %{new_status: "completed"} -> {"Run completed successfully", "success"}
          %{new_status: "failed"} -> {"Run failed", "error"}
          %{new_status: "cancelled"} -> {"Run cancelled", "warning"}
          _ -> {"Run status updated", "info"}
        end

      runs = HeartbeatEngine.list_runs_for_issue(issue_id)

      socket =
        socket
        |> assign(:runs, runs)
        |> push_event("toast", %{
          message: message,
          type: type,
          key: "run_#{issue_id}_#{payload[:new_status]}"
        })

      {:noreply, maybe_rebuild_timeline(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:document_updated, updated_document}, socket) do
    if socket.assigns.selected_document &&
         socket.assigns.selected_document.id == updated_document.id do
      revisions = Documents.list_revisions(updated_document.id)
      {:noreply, assign(socket, revisions: revisions)}
    else
      documents = Documents.list_documents(socket.assigns.issue.id)
      {:noreply, assign(socket, documents: documents)}
    end
  end

  defp status_combobox_options(current_status) do
    [
      current_status
      | Cympho.Issues.Issue.status_options() |> Enum.reject(&(&1 == current_status))
    ]
    |> Enum.map(fn status ->
      %{
        id: to_string(status),
        label: status |> to_string() |> String.replace("_", " ") |> String.capitalize()
      }
    end)
  end

  defp priority_combobox_options do
    Enum.map(Cympho.Issues.Issue.priority_options(), fn p ->
      %{id: to_string(p), label: p |> to_string() |> String.capitalize(), color: priority_dot(p)}
    end)
  end

  defp priority_dot(:critical), do: "bg-red-500"
  defp priority_dot(:high), do: "bg-red-500"
  defp priority_dot(:medium), do: "bg-amber-500"
  defp priority_dot(:low), do: "bg-ink-tertiary"
  defp priority_dot(_), do: "bg-ink-tertiary"

  defp assignee_combobox_options(agents) do
    Enum.map(agents, fn a ->
      %{id: a.id, label: a.name}
    end)
  end

  def run_status_color("completed"), do: "bg-green-400"
  def run_status_color("running"), do: "bg-blue-400 animate-pulse"
  def run_status_color("failed"), do: "bg-red-400"
  def run_status_color("pending"), do: "bg-yellow-400"
  def run_status_color("cancelled"), do: "bg-gray-400"
  def run_status_color(_), do: "bg-gray-400"

  def run_status_label("completed"), do: "Completed"
  def run_status_label("running"), do: "Running"
  def run_status_label("failed"), do: "Failed"
  def run_status_label("pending"), do: "Pending"
  def run_status_label("cancelled"), do: "Cancelled"
  def run_status_label(other), do: String.capitalize(to_string(other))

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def run_status_tone("completed"), do: "text-green-300"
  def run_status_tone("succeeded"), do: "text-green-300"
  def run_status_tone("running"), do: "text-blue-300"
  def run_status_tone("failed"), do: "text-red-300"
  def run_status_tone("timed_out"), do: "text-red-300"
  def run_status_tone("pending"), do: "text-yellow-300"
  def run_status_tone("queued"), do: "text-yellow-300"
  def run_status_tone(_), do: "text-text-tertiary"

  def format_work_product_kind(nil), do: "other"

  def format_work_product_kind(kind) do
    kind
    |> to_string()
    |> String.replace("_", " ")
  end

  def trace_status_color("success"), do: "bg-green-400"
  def trace_status_color("error"), do: "bg-red-400"
  def trace_status_color("timeout"), do: "bg-amber-400"
  def trace_status_color("pending"), do: "bg-yellow-400"
  def trace_status_color(_), do: "bg-gray-400"

  defp get_scoped_issue(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, id)
      _ -> Issues.get_issue(id)
    end
  end

  defp list_idle_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_status(:idle, company_id)
      _ -> Agents.list_agents_by_status(:idle)
    end
  end

  defp list_company_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_company(company_id)
      _ -> Agents.list_agents()
    end
  end

  def format_cost(cost) do
    "$" <>
      (cost
       |> decimal_or_zero()
       |> Decimal.round(4)
       |> Decimal.to_string(:normal))
  end

  def positive_cost?(cost), do: Decimal.compare(decimal_or_zero(cost), Decimal.new("0")) == :gt

  defp decimal_or_zero(%Decimal{} = value), do: value
  defp decimal_or_zero(value) when is_integer(value), do: Decimal.new(value)
  defp decimal_or_zero(value) when is_float(value), do: Decimal.from_float(value)
  defp decimal_or_zero(value) when is_binary(value), do: Decimal.new(value)
  defp decimal_or_zero(_), do: Decimal.new("0")

  def format_tokens(tokens) when is_integer(tokens) do
    tokens
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  def format_tokens(_), do: "0"

  def format_run_duration(run) do
    cond do
      run.started_at && run.completed_at ->
        diff = DateTime.diff(run.completed_at, run.started_at, :second)
        format_seconds(diff)

      run.started_at ->
        diff = DateTime.diff(DateTime.utc_now(), run.started_at, :second)
        format_seconds(diff)

      true ->
        "-"
    end
  end

  defp format_seconds(s) when s < 60, do: "#{s}s"
  defp format_seconds(s) when s < 3600, do: "#{div(s, 60)}m #{rem(s, 60)}s"
  defp format_seconds(s), do: "#{div(s, 3600)}h #{div(rem(s, 3600), 60)}m"

  defp try_string_to_priority("low"), do: :low
  defp try_string_to_priority("medium"), do: :medium
  defp try_string_to_priority("high"), do: :high
  defp try_string_to_priority("critical"), do: :critical
  defp try_string_to_priority(_), do: nil

  defp execution_metrics(issue, runs, work_products, child_issues, tool_call_traces) do
    comments = comments_for_issue(issue)

    %{
      comments: length(comments),
      agent_comments: Enum.count(comments, &(&1.author_type == "agent")),
      runs: length(runs),
      failed_runs: Enum.count(runs, &(&1.status in ["failed", "timed_out"])),
      work_products: length(work_products),
      code_products: Enum.count(work_products, &(&1.kind == "code_change")),
      child_issues: length(child_issues),
      open_child_issues: Enum.count(child_issues, &(&1.status not in [:done, :cancelled])),
      tool_calls: length(tool_call_traces)
    }
  end

  defp owner_brief_lines(issue, runs, work_products, child_issues) do
    latest_run = List.first(runs)
    open_children = Enum.count(child_issues, &(&1.status not in [:done, :cancelled]))

    [
      assignment_brief(issue),
      latest_run_brief(latest_run),
      artifact_brief(work_products),
      child_issue_brief(child_issues, open_children)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp evidence_gaps(issue, runs, work_products, child_issues) do
    metrics = execution_metrics(issue, runs, work_products, child_issues, [])

    [
      if(metrics.agent_comments == 0, do: "No agent completion or review comment yet."),
      if(metrics.work_products == 0, do: "No work product attached yet."),
      if(metrics.failed_runs > 0, do: "#{metrics.failed_runs} failed run needs attention."),
      if(metrics.open_child_issues > 0, do: "#{metrics.open_child_issues} sub-issue still open."),
      if(
        metrics.code_products > 0 and
          Cympho.Issues.Issue.pr_url(issue, issue.project) in [nil, ""],
        do: "Code work exists but no PR link is set."
      )
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["Evidence looks ready for review."]
      gaps -> gaps
    end
  end

  defp agent_contribution_cards(issue, runs, work_products, tool_call_traces, agents) do
    comments = comments_for_issue(issue)
    agent_by_id = Map.new(agents, &{&1.id, &1})

    ids =
      [
        issue.assignee_id,
        issue.created_by_agent_id
      ] ++
        Enum.map(Enum.filter(comments, &(&1.author_type == "agent")), & &1.author_id) ++
        Enum.map(runs, & &1.agent_id) ++
        Enum.map(work_products, & &1.created_by_agent_id) ++
        Enum.map(tool_call_traces, &(&1.agent_id || &1.actor_id))

    ids
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.map(fn agent_id ->
      agent = Map.get(agent_by_id, agent_id)

      agent_comments =
        Enum.filter(comments, &(&1.author_type == "agent" and &1.author_id == agent_id))

      agent_runs = Enum.filter(runs, &(&1.agent_id == agent_id))
      agent_products = Enum.filter(work_products, &(&1.created_by_agent_id == agent_id))

      agent_traces =
        Enum.filter(tool_call_traces, fn trace ->
          trace.agent_id == agent_id or trace.actor_id == agent_id
        end)

      %{
        id: agent_id,
        name: agent_name(agent, agent_id),
        role: agent_role(agent),
        initials: agent_initials(agent, agent_id),
        status: contribution_status(agent_runs, agent_comments, agent_products, agent_traces),
        latest_at:
          latest_contribution_at(agent_comments, agent_runs, agent_products, agent_traces),
        counts: %{
          comments: length(agent_comments),
          runs: length(agent_runs),
          products: length(agent_products),
          traces: length(agent_traces)
        },
        highlights:
          contribution_highlights(agent_comments, agent_runs, agent_products, agent_traces)
      }
    end)
    |> Enum.sort_by(
      fn card ->
        card.latest_at && DateTime.to_unix(card.latest_at)
      end,
      :desc
    )
  end

  defp comments_for_issue(%{comments: comments}) when is_list(comments), do: comments
  defp comments_for_issue(_), do: []

  defp assignment_brief(%{assignee: %{name: name}, status: status}) do
    "#{name} owns this now. Current status is #{status_label(status)}."
  end

  defp assignment_brief(%{assigned_role: role, status: status}) when role not in [nil, ""] do
    role = String.replace(role, "_", " ")
    "Waiting for #{indefinite_article(role)} #{role}. Current status is #{status_label(status)}."
  end

  defp assignment_brief(%{status: status}) do
    "No assignee yet. Current status is #{status_label(status)}."
  end

  defp latest_run_brief(nil), do: "No runtime run has been recorded yet."

  defp latest_run_brief(run) do
    label = run_status_label(run.status)
    adapter = run.adapter || "runtime"

    case run.error_reason do
      reason when reason not in [nil, ""] ->
        "Latest #{adapter} run #{String.downcase(label)}: #{reason}"

      _ ->
        "Latest #{adapter} run is #{String.downcase(label)}."
    end
  end

  defp artifact_brief([]), do: "No attached work product yet."

  defp artifact_brief(work_products) do
    kinds =
      work_products
      |> Enum.map(&format_work_product_kind(&1.kind))
      |> Enum.uniq()
      |> Enum.join(", ")

    "#{length(work_products)} work product#{plural_suffix(work_products)} attached: #{kinds}."
  end

  defp child_issue_brief([], _open_children), do: nil

  defp child_issue_brief(child_issues, 0) do
    "All #{length(child_issues)} sub-issues are closed."
  end

  defp child_issue_brief(child_issues, open_children) do
    "#{open_children} of #{length(child_issues)} sub-issues still need work."
  end

  defp contribution_status(runs, comments, products, traces) do
    latest_run = List.first(runs)

    cond do
      Enum.any?(runs, &(&1.status == "running")) -> "Running"
      latest_run && latest_run.status in ["failed", "timed_out"] -> "Needs attention"
      latest_run && latest_run.status in ["completed", "succeeded"] -> "Completed run"
      products != [] -> "Delivered artifact"
      comments != [] -> "Commented"
      traces != [] -> "Used tools"
      true -> "Assigned"
    end
  end

  defp latest_contribution_at(comments, runs, products, traces) do
    (Enum.map(comments, & &1.inserted_at) ++
       Enum.map(runs, &(&1.completed_at || &1.started_at || &1.inserted_at)) ++
       Enum.map(products, & &1.inserted_at) ++
       Enum.map(traces, &(&1.occurred_at || &1.inserted_at)))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp contribution_highlights(comments, runs, products, traces) do
    [
      latest_comment_highlight(comments),
      latest_run_highlight(runs),
      latest_product_highlight(products),
      tool_trace_highlight(traces)
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] ->
        [
          %{
            label: "Next",
            body: "No activity yet. The next run should leave a completion comment."
          }
        ]

      highlights ->
        highlights
    end
  end

  defp latest_comment_highlight([]), do: nil

  defp latest_comment_highlight(comments) do
    latest = Enum.max_by(comments, & &1.inserted_at, DateTime)
    %{label: "Commented", body: compact_body(latest.body, 180)}
  end

  defp latest_run_highlight([]), do: nil

  defp latest_run_highlight(runs) do
    latest = List.first(runs)
    detail = latest.error_reason || latest.continuation_summary || latest.log_excerpt

    %{
      label: "Runtime",
      body:
        [run_status_label(latest.status), latest.adapter, compact_body(detail, 140)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" - ")
    }
  end

  defp latest_product_highlight([]), do: nil

  defp latest_product_highlight(products) do
    latest = List.first(products)
    detail = latest.description || latest.url

    %{
      label: "Delivered",
      body:
        [latest.title, compact_body(detail, 140)]
        |> Enum.reject(&(&1 in [nil, ""]))
        |> Enum.join(" - ")
    }
  end

  defp tool_trace_highlight([]), do: nil

  defp tool_trace_highlight(traces) do
    tools =
      traces
      |> Enum.map(& &1.tool_name)
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.take(3)
      |> Enum.join(", ")

    %{
      label: "Tools",
      body: "#{length(traces)} tool calls#{if tools == "", do: "", else: ": #{tools}"}"
    }
  end

  defp compact_body(nil, _max), do: nil
  defp compact_body("", _max), do: nil

  defp compact_body(body, max) do
    body
    |> String.replace(~r/```cympho-actions.*?```/s, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> nil
      line -> truncate_text(line, max)
    end
  end

  defp truncate_text(text, max) when is_binary(text) and byte_size(text) > max do
    String.slice(text, 0, max - 1) <> "..."
  end

  defp truncate_text(text, _max), do: text

  defp agent_name(nil, id), do: "Agent #{String.slice(to_string(id), 0, 8)}"
  defp agent_name(agent, _id), do: agent.name || "Unnamed agent"

  defp agent_role(nil), do: "former agent"

  defp agent_role(agent) do
    agent.role
    |> to_string()
    |> String.replace("_", " ")
  end

  defp agent_initials(nil, id), do: id |> to_string() |> String.slice(0, 2) |> String.upcase()

  defp agent_initials(agent, _id) do
    (agent.name || "?")
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  defp plural_suffix(list) when is_list(list) and length(list) == 1, do: ""
  defp plural_suffix(_), do: "s"

  defp indefinite_article(text) do
    first = text |> to_string() |> String.downcase() |> String.first()
    if first in ["a", "e", "i", "o", "u"], do: "an", else: "a"
  end

  # Build a unified timeline of comments, interactions, runs, work_products, and tool_call_traces
  defp build_timeline(issue, runs, interactions, work_products, tool_call_traces) do
    comments_timeline =
      Enum.map(issue.comments, fn comment ->
        %{
          type: :comment,
          id: comment.id,
          timestamp: comment.inserted_at,
          data: comment
        }
      end)

    runs_timeline =
      Enum.map(runs, fn run ->
        %{
          type: :run,
          id: run.id,
          timestamp: run.inserted_at,
          data: run
        }
      end)

    interactions_timeline =
      Enum.map(interactions, fn interaction ->
        %{
          type: :interaction,
          id: interaction.id,
          timestamp: interaction.inserted_at,
          data: interaction
        }
      end)

    work_products_timeline =
      Enum.map(work_products, fn wp ->
        %{
          type: :work_product,
          id: wp.id,
          timestamp: wp.inserted_at,
          data: wp
        }
      end)

    tool_call_traces_timeline =
      Enum.map(tool_call_traces, fn trace ->
        %{
          type: :tool_call_trace,
          id: trace.id,
          timestamp: trace.occurred_at,
          data: trace
        }
      end)

    # Combine and sort by timestamp (newest last for chat view)
    (comments_timeline ++
       runs_timeline ++
       interactions_timeline ++ work_products_timeline ++ tool_call_traces_timeline)
    |> Enum.sort_by(& &1.timestamp, DateTime)
  end

  # Rebuild timeline when issue updates (status changes, etc.)
  defp maybe_rebuild_timeline(socket) do
    interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)
    work_products = WorkProducts.list_work_products(socket.assigns.issue.id)
    tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: socket.assigns.issue.id)

    timeline =
      build_timeline(
        socket.assigns.issue,
        socket.assigns.runs,
        interactions,
        work_products,
        tool_call_traces
      )

    socket
    |> assign(:timeline, timeline)
    |> assign(:interactions, interactions)
    |> assign(:work_products, work_products)
    |> assign(:tool_call_traces, tool_call_traces)
  end

  # Format timestamp for timeline entries
  def format_timeline_timestamp(%DateTime{} = dt) do
    now = DateTime.utc_now()
    diff = DateTime.diff(now, dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      diff < 604_800 -> "#{div(diff, 86400)}d ago"
      true -> Calendar.strftime(dt, "%b %d, %Y")
    end
  end

  def format_timeline_timestamp(_), do: ""

  # Check if there's a plan approval blocker for rollback
  defp check_plan_approval_blocker(document_key, issue) do
    if document_key == "plan" do
      # Check if there's an open approval for this issue
      case Cympho.Approvals.list_approvals_for_issue(issue.id) do
        approvals when is_list(approvals) ->
          open_approval = Enum.find(approvals, fn a -> a.status in [:pending, :requested] end)

          if open_approval do
            "Cannot rollback plan document while approval ##{open_approval.id} is open"
          else
            nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end
end
