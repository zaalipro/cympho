defmodule Cympho.Finances.BudgetIncident do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Finances.BudgetPolicy

  @event_types ~w(warning threshold_exceeded budget_exceeded)
  @enforcement_statuses ~w(not_applicable incomplete complete)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "budget_incidents" do
    belongs_to :budget_policy, BudgetPolicy
    belongs_to :company, Company

    field :event_type, :string
    field :spend_usd, :decimal
    field :budget_limit_usd, :decimal
    field :threshold_pct, :decimal

    # Tracks durable hard-stop cleanup for budget_exceeded + block policies.
    # incomplete → watchdog/boot re-runs stop/cancel/pause until scope is quiet.
    field :enforcement_status, :string, default: "not_applicable"

    field :resolved_at, :utc_datetime
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(budget_incident, attrs) do
    budget_incident
    |> cast(attrs, [
      :budget_policy_id,
      :company_id,
      :event_type,
      :spend_usd,
      :budget_limit_usd,
      :threshold_pct,
      :enforcement_status,
      :resolved_at,
      :metadata
    ])
    |> validate_required([
      :budget_policy_id,
      :company_id,
      :event_type,
      :spend_usd,
      :budget_limit_usd
    ])
    |> validate_inclusion(:event_type, @event_types)
    |> validate_inclusion(:enforcement_status, @enforcement_statuses)
    |> foreign_key_constraint(:budget_policy_id)
    |> foreign_key_constraint(:company_id)
  end

  def resolve_changeset(budget_incident, attrs) do
    budget_incident
    |> cast(attrs, [:resolved_at])
    |> validate_required([:resolved_at])
  end

  def enforcement_changeset(budget_incident, attrs) do
    budget_incident
    |> cast(attrs, [:enforcement_status])
    |> validate_required([:enforcement_status])
    |> validate_inclusion(:enforcement_status, @enforcement_statuses)
  end

  def event_types, do: @event_types
  def enforcement_statuses, do: @enforcement_statuses
end
