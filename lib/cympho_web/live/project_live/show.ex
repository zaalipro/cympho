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
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
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

  defp status_counts(%{id: project_id}) do
    counts =
      Issue
      |> where(project_id: ^project_id)
      |> group_by(:status)
      |> select([i], {i.status, count(i.id)})
      |> Repo.all()
      |> Map.new()

    %{
      backlog: Map.get(counts, :backlog, 0),
      todo: Map.get(counts, :todo, 0),
      in_progress: Map.get(counts, :in_progress, 0),
      in_review: Map.get(counts, :in_review, 0),
      done: Map.get(counts, :done, 0),
      blocked: Map.get(counts, :blocked, 0),
      total: Enum.sum(Map.values(counts))
    }
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
    status_counts = status_counts(project)
    health = project_health(project)
    goal_progress = Goals.list_goals_with_progress(project.id)
    project_workspaces = Workspaces.list_project_workspaces(project.id)
    secrets = list_project_secrets(project)
    env_keys = Enum.map(secrets, & &1.key)

    socket
    |> assign(:page_title, project.name)
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
    |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
    |> assign(:issues, issues)
    |> assign(:status_counts, status_counts)
    |> assign(:project_health, health)
    |> assign(:goal_progress, goal_progress)
    |> assign(:project_workspaces, project_workspaces)
    |> assign(:secrets, secrets)
    |> assign(:env_keys, env_keys)
    |> assign(
      :project_command,
      project_command(project, health, goal_progress, project_workspaces, env_keys)
    )
  end

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"
  def status_label(s), do: s |> to_string() |> String.capitalize()

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :tone, :atom, default: :neutral

  def project_command_metric(assigns) do
    ~H"""
    <div class="border-r border-border px-4 py-3 last:border-r-0">
      <p class="text-[10px] font-590 uppercase leading-3 tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
      <p class={"mt-1 font-serif text-2xl font-590 leading-none #{metric_text(@tone)}"}>
        {@value}
      </p>
    </div>
    """
  end

  defp project_health(%{company_id: company_id, id: project_id}) when is_binary(company_id) do
    company_id
    |> Projects.project_work_health()
    |> Map.get(project_id, Projects.empty_project_work_health())
  end

  defp project_health(_project), do: Projects.empty_project_work_health()

  defp project_command(project, health, goal_progress, project_workspaces, env_keys) do
    state = project_state(project, health)
    focus = project_focus(project, health, goal_progress, project_workspaces, env_keys)

    %{
      tone: state,
      badge: project_state_label(state),
      heading: project_command_heading(state),
      detail: project_command_detail(project, state, health, goal_progress, project_workspaces),
      action_label: project_command_action_label(state),
      action_path: project_command_action_path(project, state),
      focus_label: elem(focus, 0),
      focus_detail: elem(focus, 1),
      metrics: project_command_metrics(health, goal_progress, project_workspaces, env_keys)
    }
  end

  defp project_command_metrics(health, goal_progress, project_workspaces, env_keys) do
    [
      %{label: "Open", value: health.open, tone: count_tone(health.open, :ok)},
      %{label: "Progress", value: "#{health.progress_percent}%", tone: :neutral},
      %{label: "Review", value: health.in_review, tone: count_tone(health.in_review, :review)},
      %{label: "Blocked", value: health.blocked, tone: count_tone(health.blocked, :critical)},
      %{
        label: "Goals",
        value: length(goal_progress),
        tone: count_tone(length(goal_progress), :ok)
      },
      %{
        label: "Workspaces",
        value: length(project_workspaces),
        tone: count_tone(length(project_workspaces), :ok)
      },
      %{label: "Env keys", value: length(env_keys), tone: count_tone(length(env_keys), :ok)}
    ]
  end

  defp project_state(%{status: :archived}, _health), do: :archived
  defp project_state(_project, %{blocked: blocked}) when blocked > 0, do: :blocked
  defp project_state(_project, %{in_review: in_review}) when in_review > 0, do: :review
  defp project_state(_project, %{open: open}) when open > 0, do: :active
  defp project_state(_project, %{active_goals: active_goals}) when active_goals > 0, do: :planned
  defp project_state(_project, _health), do: :idle

  defp project_focus(project, health, goal_progress, project_workspaces, env_keys) do
    cond do
      health.blocked > 0 ->
        {"Blocked work", "#{health.blocked} issue(s) need escalation"}

      health.in_review > 0 ->
        {"Review queue", "#{health.in_review} issue(s) need a decision"}

      not repo_configured?(project) ->
        {"Repository setup", "Add a repo URL before agent work branches cleanly"}

      project_workspaces == [] ->
        {"Workspace setup", "Attach a project workspace for isolated execution"}

      goal_progress == [] ->
        {"Strategy link", "Add a mission or goal for this workstream"}

      env_keys == [] ->
        {"Runtime secrets", "Add project env keys when agents need provider access"}

      true ->
        {"Execution ready",
         "#{length(project_workspaces)} workspace(s), #{length(env_keys)} env key(s)"}
    end
  end

  defp project_command_heading(:blocked), do: "Clear blocked work before adding more scope"
  defp project_command_heading(:review), do: "Review waiting work so agents can continue"
  defp project_command_heading(:active), do: "Project work is moving through execution"
  defp project_command_heading(:planned), do: "Goals exist; turn them into executable issues"
  defp project_command_heading(:archived), do: "Project is archived"
  defp project_command_heading(:idle), do: "Project is ready for a sharper operating loop"

  defp project_command_detail(project, :archived, _health, _goal_progress, _project_workspaces) do
    "#{project.name} is archived. Re-activate it before assigning new agent work."
  end

  defp project_command_detail(_project, :blocked, health, _goal_progress, _project_workspaces) do
    "#{health.blocked} blocked issue(s) are stopping flow. Open the queue, resolve blockers, or hand the decision to a lead."
  end

  defp project_command_detail(_project, :review, health, _goal_progress, _project_workspaces) do
    "#{health.in_review} issue(s) are waiting for review. Approve, request changes, or reassign review ownership."
  end

  defp project_command_detail(_project, :active, health, goal_progress, project_workspaces) do
    "#{health.open} open issue(s), #{length(goal_progress)} root goal(s), and #{length(project_workspaces)} workspace(s) are connected."
  end

  defp project_command_detail(_project, :planned, _health, goal_progress, _project_workspaces) do
    "#{length(goal_progress)} root goal(s) are active, but this project needs executable issues to move."
  end

  defp project_command_detail(_project, :idle, _health, _goal_progress, _project_workspaces) do
    "Connect a goal, workspace, repo, and first issue so agents have enough context to execute independently."
  end

  defp project_command_action_label(:blocked), do: "Open project issues"
  defp project_command_action_label(:review), do: "Open reviews"
  defp project_command_action_label(:active), do: "Open project issues"
  defp project_command_action_label(:planned), do: "Create issue"
  defp project_command_action_label(:archived), do: "Edit settings"
  defp project_command_action_label(:idle), do: "Create issue"

  defp project_command_action_path(_project, :review), do: "/reviews"

  defp project_command_action_path(project, state) when state in [:planned, :idle],
    do: "/issues/new?project_id=#{project.id}"

  defp project_command_action_path(project, :archived), do: "/projects/#{project.id}/edit"
  defp project_command_action_path(project, _state), do: "/issues?project_id=#{project.id}"

  defp project_state_label(:archived), do: "Archived"
  defp project_state_label(:blocked), do: "Blocked"
  defp project_state_label(:review), do: "Review"
  defp project_state_label(:active), do: "Active"
  defp project_state_label(:planned), do: "Planned"
  defp project_state_label(:idle), do: "Idle"

  def project_state_class(:blocked), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def project_state_class(:review), do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-300"
  def project_state_class(:active), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def project_state_class(:planned), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def project_state_class(_state), do: "border-border bg-surface text-text-tertiary"

  defp project_action_class(:blocked),
    do: "border-red-500/25 bg-red-500/10 text-red-100 hover:bg-red-500/15"

  defp project_action_class(:review),
    do: "border-cyan-500/25 bg-cyan-500/10 text-cyan-100 hover:bg-cyan-500/15"

  defp project_action_class(:active),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/15"

  defp project_action_class(:planned),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp project_action_class(_state),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp metric_text(:critical), do: "text-red-300"
  defp metric_text(:review), do: "text-cyan-300"
  defp metric_text(:warning), do: "text-amber-300"
  defp metric_text(:ok), do: "text-emerald-300"
  defp metric_text(_), do: "text-text-primary"

  defp count_tone(0, _tone), do: :neutral
  defp count_tone(_count, tone), do: tone

  defp repo_configured?(project), do: not blank?(project.repo_url)
  defp blank?(value), do: is_nil(value) or value == ""

  defp workspace_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp workspace_location(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "",
    do: repo_url

  defp workspace_location(_workspace), do: "No path or repository configured"

  defp goal_type_label(type) do
    type
    |> to_string()
    |> String.capitalize()
  end

  defp goal_status_class("active"), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  defp goal_status_class("completed"), do: "border-border bg-surface text-text-tertiary"
  defp goal_status_class(_), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp progress_width(percent) when is_integer(percent),
    do: "width: #{max(min(percent, 100), 0)}%"

  defp progress_width(_percent), do: "width: 0%"
end
