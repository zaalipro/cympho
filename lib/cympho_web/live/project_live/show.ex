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
        {:noreply, put_flash(socket, :error, "Project missing company — cannot store secrets")}

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
             |> assign_project_secrets(project)
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
           |> assign_project_secrets(socket.assigns.project)
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
    socket
    |> assign(:page_title, project.name)
    |> assign(:project, project)
    |> assign(:form, to_form(Projects.change_project(project)))
    |> assign(:env_form, to_form(%{"key" => "", "value" => ""}, as: :env))
    |> assign(:issues, list_project_issues(project))
    |> assign(:status_counts, status_counts(project))
    |> assign_project_secrets(project)
  end

  defp assign_project_secrets(socket, project) do
    secrets = list_project_secrets(project)

    socket
    |> assign(:secrets, secrets)
    |> assign(:env_keys, Enum.map(secrets, & &1.key))
  end

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"
  def status_label(s), do: s |> to_string() |> String.capitalize()
end
