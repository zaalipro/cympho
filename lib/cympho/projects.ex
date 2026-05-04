defmodule Cympho.Projects do
  @moduledoc """
  The Projects context for managing projects and their CRUD operations.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Projects.Project

  @doc """
  Returns the list of projects.
  """
  def list_projects do
    Repo.all(Project)
  end

  def list_projects_by_company(company_id) do
    Project
    |> where(company_id: ^company_id)
    |> order_by([p], asc: p.name)
    |> Repo.all()
  end

  @doc """
  Sidebar projection: id, name, color, open_issue_count.
  Active projects only. Sorted: most-recently-touched first.
  """
  def list_for_sidebar(company_id) do
    open_statuses = [:backlog, :todo, :in_progress, :in_review, :blocked]

    from(p in Project,
      left_join: i in Cympho.Issues.Issue,
      on: i.project_id == p.id and i.status in ^open_statuses,
      where: p.company_id == ^company_id and p.status == :active,
      group_by: [p.id, p.name, p.color, p.updated_at],
      order_by: [desc: p.updated_at, asc: p.name],
      select: %{
        id: p.id,
        name: p.name,
        color: p.color,
        open_count: count(i.id)
      }
    )
    |> Repo.all()
  end

  @doc """
  Gets a single project by id.
  """
  def get_project!(id), do: Repo.get!(Project, id)

  @doc """
  Gets a single project by id, returns {:ok, project} or {:error, :not_found}.
  """
  def get_project(id) do
    case Repo.get(Project, id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  def get_company_project(company_id, id) do
    case Repo.one(from p in Project, where: p.id == ^id and p.company_id == ^company_id) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Gets a single project by prefix.
  """
  def get_project_by_prefix(prefix) when is_binary(prefix) do
    case Repo.get_by(Project, prefix: prefix) do
      nil -> {:error, :not_found}
      project -> {:ok, project}
    end
  end

  @doc """
  Creates a project.
  """
  def create_project(attrs \\ %{}) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a project.
  """
  def update_project(%Project{} = project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Archives a project.
  """
  def archive_project(%Project{} = project) do
    project
    |> Project.changeset(%{status: :archived})
    |> Repo.update()
  end

  @doc """
  Deletes a project.
  """
  def delete_project(%Project{} = project) do
    Repo.delete(project)
  end

  @doc """
  Subscribes to project updates.
  """
  def subscribe(company_id) do
    Phoenix.PubSub.subscribe(Cympho.PubSub, "company:#{company_id}:projects")
  end

  @doc """
  Returns a changeset for creating a new project.
  """
  def change_project(%Project{} = project, attrs \\ %{}) do
    Project.changeset(project, attrs)
  end
end
