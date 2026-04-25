defmodule Cympho.Workspaces.WorkspaceOperation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Workspaces.ExecutionWorkspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "workspace_operations" do
    field :phase, :string
    field :command, :string
    field :cwd, :string
    field :status, :string
    field :exit_code, :integer
    field :log_store, :string
    field :log_ref, :string
    field :log_bytes, :integer
    field :log_sha256, :string
    field :log_compressed, :boolean, default: false
    field :stdout_excerpt, :string
    field :stderr_excerpt, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :company, Company
    belongs_to :execution_workspace, ExecutionWorkspace
    belongs_to :heartbeat_run, Cympho.Wakes.Wake, foreign_key: :heartbeat_run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(workspace_operation, attrs) do
    workspace_operation
    |> cast(attrs, [
      :phase,
      :command,
      :cwd,
      :status,
      :exit_code,
      :log_store,
      :log_ref,
      :log_bytes,
      :log_sha256,
      :log_compressed,
      :stdout_excerpt,
      :stderr_excerpt,
      :metadata,
      :started_at,
      :finished_at,
      :company_id,
      :execution_workspace_id,
      :heartbeat_run_id
    ])
    |> validate_required([:phase, :status, :company_id, :execution_workspace_id])
  end
end
