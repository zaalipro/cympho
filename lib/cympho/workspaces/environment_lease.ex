defmodule Cympho.Workspaces.EnvironmentLease do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Workspaces.Environment
  alias Cympho.Workspaces.ExecutionWorkspace

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "environment_leases" do
    field :status, :string
    field :lease_policy, :string
    field :provider, :string
    field :provider_lease_id, :string
    field :acquired_at, :utc_datetime
    field :last_used_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :released_at, :utc_datetime
    field :failure_reason, :string
    field :cleanup_status, :string
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :environment, Environment
    belongs_to :execution_workspace, ExecutionWorkspace
    belongs_to :issue, Cympho.Issues.Issue
    belongs_to :heartbeat_run, Cympho.Wakes.Wake, foreign_key: :heartbeat_run_id

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(environment_lease, attrs) do
    environment_lease
    |> cast(attrs, [
      :status,
      :lease_policy,
      :provider,
      :provider_lease_id,
      :acquired_at,
      :last_used_at,
      :expires_at,
      :released_at,
      :failure_reason,
      :cleanup_status,
      :metadata,
      :company_id,
      :environment_id,
      :execution_workspace_id,
      :issue_id,
      :heartbeat_run_id
    ])
    |> validate_required([:status, :company_id, :environment_id])
  end

  @doc false
  def revoke_changeset(environment_lease) do
    environment_lease
    |> change(%{status: "released", released_at: DateTime.utc_now()})
  end
end
