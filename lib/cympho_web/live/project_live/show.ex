defmodule CymphoWeb.ProjectLive.Show do
  use CymphoWeb, :live_view
  import Ecto.Query
  alias Cympho.{Projects, Repo, Secrets}
  alias Cympho.Issues.Issue

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Projects.subscribe(socket.assigns.current_company.id)
    end

    case scoped_get_project(id, socket) do
      {:ok, project} ->
        {:ok,
         socket
         |> assign(:project, project)
         |> assign(:issues, list_project_issues(project))
         |> assign(:status_counts, status_counts(project))
         |> assign(:env_keys, list_env_keys(project))}

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
        socket
        |> assign(:page_title, project.name)
        |> assign(:project, project)
        |> assign(:issues, list_project_issues(project))
        |> assign(:status_counts, status_counts(project))
        |> assign(:env_keys, list_env_keys(project))

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
  def handle_info({:project_updated, updated_project}, socket) do
    if socket.assigns.project.id == updated_project.id do
      {:noreply,
       socket
       |> assign(:project, updated_project)
       |> assign(:env_keys, list_env_keys(updated_project))}
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

  defp list_env_keys(%{id: id, company_id: company_id}) when is_binary(company_id) do
    company_id
    |> Secrets.list_secrets(scope: "project", scope_id: id)
    |> Enum.map(& &1.key)
  end

  defp list_env_keys(_), do: []

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"
  def status_label(s), do: s |> to_string() |> String.capitalize()
end
