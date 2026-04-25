defmodule Cympho.Workspaces.ExecutionWorkspace do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project
  alias Cympho.Workspaces.ProjectWorkspace
  alias Cympho.Workspaces.RuntimeService
  alias Cympho.Workspaces.WorkspaceOperation
  alias Cympho.Workspaces.EnvironmentLease

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "execution_workspaces" do
    field :mode, :string
    field :strategy_type, :string
    field :name, :string
    field :status, :string
    field :cwd, :string
    field :repo_url, :string
    field :base_ref, :string
    field :branch_name, :string
    field :provider_type, :string
    field :provider_ref, :string
    field :derived_from_execution_workspace_id, :binary_id
    field :last_used_at, :utc_datetime
    field :opened_at, :utc_datetime
    field :closed_at, :utc_datetime
    field :cleanup_eligible_at, :utc_datetime
    field :cleanup_reason, :string
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :project, Project
    belongs_to :project_workspace, ProjectWorkspace
    belongs_to :source_issue, Cympho.Issues.Issue, foreign_key: :source_issue_id

    has_many :runtime_services, RuntimeService, foreign_key: :execution_workspace_id
    has_many :operations, WorkspaceOperation, foreign_key: :execution_workspace_id
    has_many :leases, EnvironmentLease, foreign_key: :execution_workspace_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(execution_workspace, attrs) do
    execution_workspace
    |> cast(attrs, [
      :mode,
      :strategy_type,
      :name,
      :status,
      :cwd,
      :repo_url,
      :base_ref,
      :branch_name,
      :provider_type,
      :provider_ref,
      :derived_from_execution_workspace_id,
      :last_used_at,
      :opened_at,
      :closed_at,
      :cleanup_eligible_at,
      :cleanup_reason,
      :metadata,
      :company_id,
      :project_id,
      :project_workspace_id,
      :source_issue_id
    ])
    |> validate_required([:name, :project_id, :company_id, :project_workspace_id])
  end
end
