defmodule CymphoWeb.IssueLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Agents
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Projects

  @default_attrs %{"status" => "todo", "priority" => "medium"}

  @impl true
  def mount(params, _session, socket) do
    projects = list_projects(socket)
    scope = issue_scope(socket, params, projects)
    changeset = Issues.change_issue(%Issue{}, Map.merge(@default_attrs, scope))

    {:ok,
     socket
     |> assign(:page_title, "New Issue")
     |> assign(:projects, projects)
     |> assign(:issue_scope, scope)
     |> assign(:intake_route, intake_route(scope, socket.assigns[:current_company]))
     |> assign(:runtime_enabled?, Dispatcher.enabled?())
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
  def handle_event(
        "save",
        %{"issue" => _issue_params},
        %{assigns: %{current_company: nil}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "Choose a company before creating issues.")}
  end

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

  def project_options(projects) do
    Enum.map(projects, &{&1.name, &1.id})
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

  defp issue_scope(socket, params, projects) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        project_id = selected_project_id(params["project_id"], projects)

        attrs =
          %{"company_id" => company_id, "project_id" => project_id}
          |> route_owner_request_to_ceo(company_id)

        case socket.assigns[:current_user] do
          %{id: user_id} -> Map.put(attrs, "created_by_user_id", user_id)
          _ -> attrs
        end

      _ ->
        %{}
    end
  end

  defp list_projects(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.list_projects_by_company(company_id)
      _ -> []
    end
  end

  defp selected_project_id(project_id, projects) when is_binary(project_id) do
    if Enum.any?(projects, &(&1.id == project_id)) do
      project_id
    else
      selected_project_id(nil, projects)
    end
  end

  defp selected_project_id(_project_id, [project | _projects]), do: project.id
  defp selected_project_id(_project_id, []), do: nil

  defp route_owner_request_to_ceo(attrs, company_id) do
    case Agents.get_company_ceo(company_id) do
      {:ok, ceo} -> Map.merge(attrs, %{"assignee_id" => ceo.id, "assigned_role" => "ceo"})
      {:error, :not_found} -> attrs
    end
  end

  defp intake_route(%{"assignee_id" => agent_id, "assigned_role" => role}, %{id: company_id}) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, agent} -> %{agent: agent, role: role}
      {:error, _} -> nil
    end
  end

  defp intake_route(_scope, _company), do: nil
end
