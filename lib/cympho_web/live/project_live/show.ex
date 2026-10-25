defmodule CymphoWeb.ProjectLive.Show do
  use CymphoWeb, :live_view
  import Ecto.Query
  alias Cympho.{Goals, Projects, Repo, Secrets, Workspaces}
  alias Cympho.Issues.Issue

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Projects.subscribe(socket.assigns.current_company.id)
    end

    case scoped_get_project(id, socket) do
      {:ok, project} ->
        {:ok, assign_project(socket, project)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/projects")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, url, socket) do
    # The router gives /edit no live_action (router.ex), so the path tells them apart.
    editing? = url |> URI.parse() |> Map.get(:path, "") |> String.ends_with?("/edit")

    {:noreply,
     socket
     |> assign(:editing?, editing?)
     |> apply_action(socket.assigns.live_action, id)}
  end

  defp apply_action(socket, nil, id), do: apply_action(socket, :show, id)

  defp apply_action(socket, :show, id) do
    case scoped_get_project(id, socket) do
      {:ok, project} ->
        assign_project(socket, project)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Project not found")
        |> push_navigate(to: ~p"/projects")
    end
  end

  defp scoped_get_project(id, socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.get_company_project(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_event("save", %{"project" => project_params}, socket) do
    case Projects.update_project(socket.assigns.project, project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign_project(project)
         |> put_flash(:info, "Project updated")}

      {:error, changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  def handle_event("add_env", %{"env" => %{"key" => key, "value" => value}}, socket) do
    project = socket.assigns.project
    key = key |> to_string() |> String.trim() |> String.upcase()

    cond do
      key == "" or value in [nil, ""] ->
        {:noreply, put_flash(socket, :error, "Key and value are required")}

      not String.match?(key, ~r/^[A-Z][A-Z0-9_]*$/) ->
        {:noreply,
         put_flash(socket, :error, "Key must be uppercase letters, digits, underscores")}

      project.company_id == nil ->
        {:noreply, put_flash(socket, :error, "Project missing company - cannot store secrets")}

      true ->
        attrs = %{
          company_id: project.company_id,
          scope: "project",
          scope_id: project.id,
          key: key,
          value: value,
          description: "Project env var"
        }

        case Secrets.create_secret(attrs) do
          {:ok, _secret} ->
            {:noreply,
             socket
             |> assign_project(project)
             |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
             |> put_flash(:info, "Added #{key}")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not save env var")}
        end
    end
  end

  def handle_event("delete_env", %{"id" => id}, socket) do
    case Secrets.get_secret(id) do
      {:ok, secret} ->
        if secret_belongs_to_project?(secret, socket.assigns.project) do
          {:ok, _} = Secrets.delete_secret(secret)

          {:noreply,
           socket
           |> assign_project(socket.assigns.project)
           |> put_flash(:info, "Removed #{secret.key}")}
        else
          {:noreply, put_flash(socket, :error, "Environment variable not found")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "Environment variable not found")}
    end
  end

  @impl true
  def handle_info({:project_updated, updated_project}, socket) do
    if socket.assigns.project.id == updated_project.id do
      {:noreply, assign_project(socket, updated_project)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:project_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/projects")}
  end

  defp list_project_issues(%{id: project_id}) do
    Issue
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp list_project_secrets(%{id: id, company_id: company_id}) when is_binary(company_id) do
    Secrets.list_secrets(company_id, scope: "project", scope_id: id)
  end

  defp list_project_secrets(_), do: []

  defp secret_belongs_to_project?(secret, project) do
    secret.company_id == project.company_id and secret.scope == "project" and
      secret.scope_id == project.id
  end

  defp assign_project(socket, project) do
    issues = list_project_issues(project)
    health = project_health(project)
    goal_progress = Goals.list_goals_with_progress(project.id)
    project_workspaces = Workspaces.list_project_workspaces(project.id)
    secrets = list_project_secrets(project)

    socket
    |> assign(:page_title, project.name)
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
    |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
    |> assign(:issues, issues)
    |> assign(:goal_progress, goal_progress)
    |> assign(:project_workspaces, project_workspaces)
    |> assign(:secrets, secrets)
    |> assign(:project_health, health)
    |> assign(
      :project_command,
      project_command(project, health, goal_progress, project_workspaces)
    )
  end

  defp project_health(%{company_id: company_id, id: project_id}) when is_binary(company_id) do
    company_id
    |> Projects.project_work_health()
    |> Map.get(project_id, Projects.empty_project_work_health())
  end

  defp project_health(_project), do: Projects.empty_project_work_health()

  defp project_command(project, health, goal_progress, project_workspaces) do
    state = project_state(project, health)

    %{
      heading: project_command_heading(state),
      detail: project_command_detail(project, state, health, goal_progress, project_workspaces),
      action_label: project_command_action_label(state),
      action_path: project_command_action_path(project, state)
    }
  end

  defp project_state(%{status: :archived}, _health), do: :archived
  defp project_state(_project, %{blocked: blocked}) when blocked > 0, do: :blocked
  defp project_state(_project, %{in_review: in_review}) when in_review > 0, do: :review
  defp project_state(_project, %{open: open}) when open > 0, do: :active
  defp project_state(_project, %{active_goals: active_goals}) when active_goals > 0, do: :planned
  defp project_state(_project, _health), do: :idle

  defp project_command_heading(:blocked), do: "Clear blocked work before adding more scope"
  defp project_command_heading(:review), do: "Review waiting work so agents can continue"
  defp project_command_heading(:active), do: "Project work is moving through execution"
  defp project_command_heading(:planned), do: "Goals exist; turn them into tasks"
  defp project_command_heading(:archived), do: "Project is archived"
  defp project_command_heading(:idle), do: "Project is ready for a sharper operating loop"

  # Owner-facing copy should read like a sentence, not a form field:
  # "1 issue is waiting", not "1 issue(s) are waiting".
  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"

  defp verb(1, singular, _plural), do: singular
  defp verb(_n, _singular, plural), do: plural

  defp project_command_detail(project, :archived, _health, _goal_progress, _project_workspaces) do
    "#{project.name} is archived. Re-activate it before assigning new agent work."
  end

  defp project_command_detail(_project, :blocked, health, _goal_progress, _project_workspaces) do
    "#{health.blocked} blocked #{plural(health.blocked, "task")} #{verb(health.blocked, "is", "are")} stopping flow. Open the queue, resolve blockers, or hand the decision to a lead."
  end

  defp project_command_detail(_project, :review, health, _goal_progress, _project_workspaces) do
    "#{health.in_review} #{plural(health.in_review, "task")} #{verb(health.in_review, "is", "are")} waiting for review. Approve, request changes, or reassign review ownership."
  end

  defp project_command_detail(_project, :active, health, goal_progress, project_workspaces) do
    "#{health.open} open #{plural(health.open, "task")}, #{length(goal_progress)} root #{plural(length(goal_progress), "goal")}, and #{length(project_workspaces)} #{plural(length(project_workspaces), "work folder")} connected."
  end

  defp project_command_detail(_project, :planned, _health, goal_progress, _project_workspaces) do
    "#{length(goal_progress)} root #{plural(length(goal_progress), "goal")} #{verb(length(goal_progress), "is", "are")} active, but this project needs tasks to move."
  end

  defp project_command_detail(_project, :idle, _health, _goal_progress, _project_workspaces) do
    "Connect a goal, work folder, repo, and first task so agents have enough context to work on their own."
  end

  defp project_command_action_label(:blocked), do: "Open project tasks"
  defp project_command_action_label(:review), do: "Open reviews"
  defp project_command_action_label(:active), do: "Open project tasks"
  defp project_command_action_label(:planned), do: "Create task"
  defp project_command_action_label(:archived), do: "Edit settings"
  defp project_command_action_label(:idle), do: "Create task"

  defp project_command_action_path(_project, :review), do: "/reviews"

  defp project_command_action_path(project, state) when state in [:planned, :idle],
    do: "/issues/new?project_id=#{project.id}"

  defp project_command_action_path(project, :archived), do: "/projects/#{project.id}/edit"
  defp project_command_action_path(project, _state), do: "/issues?project_id=#{project.id}"

  defp workspace_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp workspace_location(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "",
    do: repo_url

  defp workspace_location(_workspace), do: "No path or repository configured"

  defp goal_type_label(type) do
    type
    |> to_string()
    |> String.capitalize()
  end
end
