defmodule Cympho.Workspaces.ProjectWorkspace do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project
  alias Cympho.Workspaces.ExecutionWorkspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "project_workspaces" do
    field :name, :string
    field :cwd, :string
    field :repo_url, :string
    field :repo_ref, :string
    field :default_ref, :string
    field :metadata, :map, default: %{}
    field :is_primary, :boolean, default: false
    field :source_type, :string
    field :visibility, :string
    field :setup_command, :string
    field :cleanup_command, :string
    field :remote_provider, :string
    field :remote_workspace_ref, :string
    field :shared_workspace_key, :string

    belongs_to :company, Company
    belongs_to :project, Project

    has_many :execution_workspaces, ExecutionWorkspace, foreign_key: :project_workspace_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(project_workspace, attrs) do
    project_workspace
    |> cast(attrs, [
      :name,
      :cwd,
      :repo_url,
      :repo_ref,
      :default_ref,
      :metadata,
      :is_primary,
      :source_type,
      :visibility,
      :setup_command,
      :cleanup_command,
      :remote_provider,
      :remote_workspace_ref,
      :shared_workspace_key,
      :company_id,
      :project_id
    ])
    |> validate_required([:name, :project_id, :company_id])
  end
end
