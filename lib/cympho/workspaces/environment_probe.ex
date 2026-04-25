defmodule Cympho.Workspaces.EnvironmentProbe do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Workspaces.Environment
  alias Cympho.Workspaces.ExecutionWorkspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environment_probes" do
    field :probe_type, :string
    field :status, :string
    field :result, :map, default: %{}
    field :last_checked_at, :utc_datetime
    field :next_check_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :environment, Environment
    belongs_to :execution_workspace, ExecutionWorkspace

    timestamps(type: :utc_datetime)
  end

  def changeset(probe, attrs) do
    probe
    |> cast(attrs, [
      :probe_type,
      :status,
      :result,
      :last_checked_at,
      :next_check_at,
      :metadata,
      :company_id,
      :environment_id,
      :execution_workspace_id
    ])
    |> validate_required([:probe_type, :company_id])
  end
end
