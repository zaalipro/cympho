defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  use CymphoWeb, :html
  alias Cympho.Issues
  alias Cympho.Comments
  alias Cympho.Agents
  alias Cympho.Documents
  alias Cympho.Orchestrator
  alias Cympho.HeartbeatEngine

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    Issues.subscribe()
    Comments.subscribe()
    Documents.subscribe()

    case Issues.get_issue(id) do
      {:ok, issue} ->
        comment_changeset = Comments.Comment.changeset(%Comments.Comment{}, %{})
        runs = HeartbeatEngine.list_runs_for_issue(issue.id)

        {:ok,
         assign(socket,
           issue: issue,
           comment_changeset: comment_changeset,
           comment_form: to_form(comment_changeset),
           agents: Agents.list_agents_by_status(:idle),
           all_agents: Agents.list_agents(),
           show_agent_panel: false,
           editing: nil,
           assignee_search: "",
           runs: runs
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
    case Issues.get_issue(id) do
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
      "blocked" => :blocked
    }

    case Map.fetch(status_atoms, status) do
      {:ok, status_atom} ->
        case Issues.update_issue(socket.assigns.issue, %{status: status_atom}) do
          {:ok, _issue} ->
            {:noreply, socket}

          {:error, _changeset} ->
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
          {:ok, _issue} -> {:noreply, socket}
          {:error, _changeset} -> {:noreply, put_flash(socket, :error, "Failed to update priority")}
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

    case Orchestrator.start_and_run(issue, agent_id) do
      {:ok, _pid} ->
        {:ok, _updated_agent} =
          Agents.update_agent(%Agents.Agent{id: agent_id}, %{status: :running})

        {:noreply,
         socket
         |> put_flash(:info, "Agent spawned successfully")
         |> assign(:show_agent_panel, false)
         |> assign(:agents, Agents.list_agents_by_status(:idle))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to spawn agent: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info({:issue_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      runs = HeartbeatEngine.list_runs_for_issue(updated_issue.id)
      {:noreply, assign(socket, issue: updated_issue, runs: runs)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:issue_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end

  def handle_info({:comment_created, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_updated, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:comment_deleted, updated_issue}, socket) do
    if socket.assigns.issue.id == updated_issue.id do
      {:noreply, assign(socket, :issue, updated_issue)}
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

  defp valid_status_options(current_status) do
    all = [
      {"Backlog", "backlog"},
      {"Todo", "todo"},
      {"In progress", "in_progress"},
      {"In review", "in_review"},
      {"Done", "done"},
      {"Blocked", "blocked"}
    ]

    current_str = to_string(current_status)
    Enum.reject(all, fn {_, value} -> value == current_str end)
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

  def format_cost(cost) when not is_nil(cost) do
    "$" <> (:erlang.float_to_binary(cost / 1, decimals: 4))
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
end
