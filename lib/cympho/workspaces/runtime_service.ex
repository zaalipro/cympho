defmodule Cympho.Workspaces.RuntimeService do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project
  alias Cympho.Workspaces.ProjectWorkspace
  alias Cympho.Workspaces.ExecutionWorkspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_runtime_services" do
    field :scope_type, :string
    field :scope_id, :binary_id
    field :service_name, :string
    field :status, :string
    field :lifecycle, :string
    field :reuse_key, :string
    field :command, :string
    field :cwd, :string
    field :port, :integer
    field :url, :string
    field :provider, :string
    field :provider_ref, :string
    field :owner_agent_id, :binary_id
    field :started_by_run_id, :binary_id
    field :last_used_at, :utc_datetime
    field :started_at, :utc_datetime
    field :stopped_at, :utc_datetime
    field :stop_policy, :map, default: %{}
    field :health_status, :string

    belongs_to :company, Company
    belongs_to :project, Project
    belongs_to :project_workspace, ProjectWorkspace
    belongs_to :issue, Cympho.Issues.Issue
    belongs_to :execution_workspace, ExecutionWorkspace

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(runtime_service, attrs) do
    runtime_service
    |> cast(attrs, [
      :scope_type,
      :scope_id,
      :service_name,
      :status,
      :lifecycle,
      :reuse_key,
      :command,
      :cwd,
      :port,
      :url,
      :provider,
      :provider_ref,
      :owner_agent_id,
      :started_by_run_id,
      :last_used_at,
      :started_at,
      :stopped_at,
      :stop_policy,
      :health_status,
      :company_id,
      :project_id,
      :project_workspace_id,
      :issue_id,
      :execution_workspace_id
    ])
    |> validate_required([:service_name, :status, :company_id, :project_id])
  end
end
