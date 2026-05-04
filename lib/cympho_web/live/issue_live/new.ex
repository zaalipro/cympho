defmodule CymphoWeb.IssueLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Projects

  @default_attrs %{"status" => "backlog", "priority" => "medium"}

  @impl true
  def mount(_params, _session, socket) do
    scope = issue_scope(socket)
    changeset = Issues.change_issue(%Issue{}, Map.merge(@default_attrs, scope))

    {:ok,
     socket
     |> assign(:page_title, "New Issue")
     |> assign(:issue_scope, scope)
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"issue" => issue_params}, socket) do
    changeset =
      %Issue{}
      |> Issues.change_issue(
        @default_attrs
        |> Map.merge(socket.assigns.issue_scope)
        |> Map.merge(issue_params)
      )
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"issue" => issue_params}, socket) do
    params = @default_attrs |> Map.merge(socket.assigns.issue_scope) |> Map.merge(issue_params)

    case Issues.create_issue(params) do
      {:ok, _issue} ->
        {:noreply, push_navigate(socket, to: ~p"/issues")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def status_options do
    Issue.status_options()
    |> Enum.map(fn status -> {status_label(status), to_string(status)} end)
  end

  def priority_options do
    Issue.priority_options()
    |> Enum.map(fn priority -> {priority_label(priority), to_string(priority)} end)
  end

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:done), do: "Done"
  defp status_label(:cancelled), do: "Cancelled"

  defp priority_label(priority) do
    priority
    |> to_string()
    |> String.capitalize()
  end

  defp issue_scope(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        project_id =
          company_id
          |> Projects.list_projects_by_company()
          |> List.first()
          |> case do
            nil -> nil
            project -> project.id
          end

        attrs = %{"company_id" => company_id, "project_id" => project_id}

        case socket.assigns[:current_user] do
          %{id: user_id} -> Map.put(attrs, "created_by_user_id", user_id)
          _ -> attrs
        end

      _ ->
        %{}
    end
  end
end
