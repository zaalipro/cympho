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
           show_agent_panel: false,
           editing: nil,
           assignee_search: "",
           runs: runs,
           interactions: interactions,
           work_products: work_products,
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
            {:noreply, assign(socket, issue: issue)}

          {:error, :invalid_transition} ->
            {:noreply, put_flash(socket, :error, "Invalid status transition")}

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
          {:ok, _issue} ->
            {:noreply, socket}

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
      {:ok, issue} -> {:noreply, assign(socket, issue: issue, editing: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update title")}
    end
  end

  @impl true
  def handle_event("save_description", %{"description" => description}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{description: description}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue, editing: nil)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update description")}
    end
  end

  @impl true
  def handle_event("update_github_pr_url", %{"github_pr_url" => url}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_url: url}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to update PR URL")}
    end
  end

  @impl true
  def handle_event("clear_github_pr_url", _params, socket) do
    case Issues.update_issue(socket.assigns.issue, %{github_pr_url: nil}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to clear PR URL")}
    end
  end

  @impl true
  def handle_event("search_assignee", %{"q" => q}, socket) do
    {:noreply, assign(socket, assignee_search: q)}
  end

  @impl true
  def handle_event("assign_issue", %{"agent_id" => agent_id}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{assignee_id: agent_id}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue, assignee_search: "")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to assign issue")}
    end
  end

  @impl true
  def handle_event("unassign_issue", _params, socket) do
    case Issues.update_issue(socket.assigns.issue, %{assignee_id: nil}) do
      {:ok, issue} -> {:noreply, assign(socket, issue: issue)}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to unassign issue")}
    end
  end

  @impl true
  def handle_event("toggle_agent_panel", _, socket) do
    {:noreply, update(socket, :show_agent_panel, &(!&1))}
  end

  @impl true
  def handle_event("spawn_agent", %{"agent_id" => agent_id}, socket) do
    issue = socket.assigns.issue

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

  @impl true
  def handle_info({:issue_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      runs = HeartbeatEngine.list_runs_for_issue(updated_issue.id)

      socket =
        socket
        |> assign(issue: updated_issue, runs: runs)
        |> push_event("toast", %{
          message: "Issue updated by another user",
          type: "info",
          key: "issue_#{updated_issue.id}_updated"
        })

      {:noreply, maybe_rebuild_timeline(socket)}
    else
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

  defp valid_status_options(current_status) do
    current_status
    |> Cympho.Issues.StateMachine.valid_transitions()
    |> Enum.map(fn status ->
      {status |> to_string() |> String.replace("_", " ") |> String.capitalize(),
       to_string(status)}
    end)
  end

  defp filtered_agents(all_agents, search) do
    search = String.downcase(search)

    Enum.filter(all_agents, fn agent ->
      String.contains?(String.downcase(agent.name), search) or
        String.contains?(String.downcase(to_string(agent.role)), search)
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

  def format_cost(cost) when not is_nil(cost) do
    "$" <> :erlang.float_to_binary(cost / 1, decimals: 4)
  end

  def format_cost(_), do: "$0.00"

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
