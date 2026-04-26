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
