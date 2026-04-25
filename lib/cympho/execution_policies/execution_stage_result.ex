defmodule Cympho.ExecutionPolicies.ExecutionStageResult do
  @moduledoc """
  Tracks the execution and completion of stages within an execution policy.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "execution_stage_results" do
    field :stage_name, :string
    field :stage_index, :integer
    field :status, :string, default: "pending"
    field :outcome, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :actor_type, :string
    field :actor_id, :binary_id
    field :approval_id, :binary_id
    field :decision_id, :binary_id
    field :notes, :string
    field :metadata, :map, default: %{}

    belongs_to :execution_policy, ExecutionPolicy
    belongs_to :company, Company

    timestamps(type: :utc_datetime)
  end

  def changeset(stage_result, attrs) do
    stage_result
    |> cast(attrs, [
      :stage_name,
      :stage_index,
      :status,
      :outcome,
      :started_at,
      :completed_at,
      :actor_type,
      :actor_id,
      :approval_id,
      :decision_id,
      :notes,
      :metadata,
      :execution_policy_id,
      :resource_type,
      :resource_id,
      :company_id
    ])
    |> validate_required([
      :stage_name,
      :stage_index,
      :status,
      :execution_policy_id,
      :resource_type,
      :resource_id,
      :company_id
    ])
    |> validate_inclusion(:status, ["pending", "in_progress", "completed", "failed", "skipped", "cancelled"])
    |> validate_inclusion(:outcome, ["approved", "rejected", "deferred", "implemented", "failed"])
    |> validate_stage_index()
    |> validate_completion_ordering()
    |> assoc_constraint(:execution_policy)
    |> assoc_constraint(:company)
    |> unique_constraint([:execution_policy_id, :resource_type, :resource_id, :stage_index],
      name: :unique_stage_per_resource
    )
  end

  def start_changeset(stage_result, attrs) do
    stage_result
    |> changeset(attrs)
    |> put_change(:status, "in_progress")
    |> put_change(:started_at, DateTime.utc_now())
  end

  def complete_changeset(stage_result, attrs) do
    stage_result
    |> changeset(attrs)
    |> put_change(:status, "completed")
    |> put_change(:completed_at, DateTime.utc_now())
  end

  def fail_changeset(stage_result, attrs) do
    stage_result
    |> changeset(attrs)
    |> put_change(:status, "failed")
    |> put_change(:completed_at, DateTime.utc_now())
  end

  def skip_changeset(stage_result, attrs) do
    stage_result
    |> changeset(attrs)
    |> put_change(:status, "skipped")
    |> put_change(:completed_at, DateTime.utc_now())
  end

  def pending?(%__MODULE__{status: "pending"}), do: true
  def pending?(%__MODULE__{}), do: false

  def in_progress?(%__MODULE__{status: "in_progress"}), do: true
  def in_progress?(%__MODULE__{}), do: false

  def completed?(%__MODULE__{status: "completed"}), do: true
  def completed?(%__MODULE__{}), do: false

  def failed?(%__MODULE__{status: "failed"}), do: true
  def failed?(%__MODULE__{}), do: false

  def skipped?(%__MODULE__{status: "skipped"}), do: true
  def skipped?(%__MODULE__{}), do: false

  def terminal?(%__MODULE__{} = stage_result) do
    stage_result.status in ["completed", "failed", "skipped", "cancelled"]
  end

  def can_start?(%__MODULE__{} = stage_result) do
    pending?(stage_result) or failed?(stage_result)
  end

  defp validate_stage_index(changeset) do
    stage_index = get_change(changeset, :stage_index)

    if stage_index && stage_index < 0 do
      add_error(changeset, :stage_index, "must be non-negative")
    else
      changeset
    end
  end

  defp validate_completion_ordering(changeset) do
    started_at = get_change(changeset, :started_at)
    completed_at = get_change(changeset, :completed_at)

    if started_at && completed_at && DateTime.compare(started_at, completed_at) == :gt do
      add_error(changeset, :completed_at, "must be after started_at")
    else
      changeset
    end
  end
end
