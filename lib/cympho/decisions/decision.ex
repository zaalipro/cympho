defmodule Cympho.Decisions.Decision do
  @moduledoc """
  Decision tracking for governance actions with reversal support.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Cympho.Decisions.{Decision, DecisionReversal}
  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "decisions" do
    field :decision_type, :string
    field :decision_key, :string
    field :outcome, :string
    field :context, :map, default: %{}
    field :reasoning, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :resource_type, :string
    field :resource_id, :binary_id
    field :parent_decision_id, :binary_id
    field :effective_at, :utc_datetime
    field :expires_at, :utc_datetime
    field :status, :string, default: "active"
    field :reversible, :boolean, default: true
    field :reversed_by_id, :binary_id
    field :reversed_at, :utc_datetime
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    has_many :child_decisions, Decision, foreign_key: :parent_decision_id
    belongs_to :parent_decision, Decision, define_field: false
    belongs_to :reversed_by, Decision, define_field: false
    has_many :reversals, DecisionReversal, foreign_key: :original_decision_id
    has_many :reversing_reversals, DecisionReversal, foreign_key: :reversing_decision_id

    timestamps(type: :utc_datetime)
  end

  def changeset(decision, attrs) do
    decision
    |> cast(attrs, [
      :decision_type,
      :decision_key,
      :outcome,
      :context,
      :reasoning,
      :actor_type,
      :actor_id,
      :resource_type,
      :resource_id,
      :parent_decision_id,
      :effective_at,
      :expires_at,
      :status,
      :reversible,
      :reversed_by_id,
      :reversed_at,
      :metadata,
      :company_id
    ])
    |> validate_required([
      :decision_type,
      :decision_key,
      :outcome,
      :actor_type,
      :actor_id,
      :company_id
    ])
    |> validate_inclusion(:outcome, ["approved", "denied", "deferred", "cancelled", "implemented", "reversed"])
    |> validate_inclusion(:status, ["active", "expired", "reversed", "superseded"])
    |> validate_decision_key_unique()
    |> validate_effective_at()
    |> validate_expires_after_effective()
    |> assoc_constraint(:company)
    |> assoc_constraint(:parent_decision)
  end

  def create_changeset(decision, attrs) do
    decision
    |> changeset(attrs)
    |> put_change(:effective_at, DateTime.utc_now())
    |> put_change(:status, "active")
  end

  def reversal_changeset(decision, attrs) do
    decision
    |> changeset(attrs)
    |> put_change(:status, "reversed")
    |> put_change(:reversed_at, DateTime.utc_now())
  end

  def active?(%Decision{status: "active"}), do: true
  def active?(%Decision{}), do: false

  def expired?(%Decision{expires_at: nil}), do: false
  def expired?(%Decision{expires_at: expires_at}), do: DateTime.compare(expires_at, DateTime.utc_now()) == :lt

  def reversible?(%Decision{reversible: true, reversed_by_id: nil}), do: true
  def reversible?(%Decision{}), do: false

  def can_reverse?(%Decision{} = decision) do
    active?(decision) and reversible?(decision) and not expired?(decision)
  end

  defp validate_decision_key_unique(changeset) do
    decision_key = get_change(changeset, :decision_key)
    parent_id = get_change(changeset, :parent_decision_id)
    company_id = get_field(changeset, :company_id)
    status = get_change(changeset, :status, "active")

    if decision_key && parent_id && company_id && status == "active" do
      query =
        from d in Decision,
          where:
            d.decision_key == ^decision_key and
              d.parent_decision_id == ^parent_id and
              d.company_id == ^company_id and
              d.status == "active",
          select: count(d.id)

      if Cympho.Repo.one(query) > 0 do
        add_error(changeset, :decision_key, "has already been used for this parent decision")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_effective_at(changeset) do
    effective_at = get_change(changeset, :effective_at)

    if effective_at && DateTime.compare(effective_at, DateTime.utc_now()) == :gt do
      add_error(changeset, :effective_at, "cannot be in the future")
    else
      changeset
    end
  end

  defp validate_expires_after_effective(changeset) do
    effective_at = get_change(changeset, :effective_at)
    expires_at = get_change(changeset, :expires_at)

    if effective_at && expires_at && DateTime.compare(effective_at, expires_at) == :gt do
      add_error(changeset, :expires_at, "must be after effective_at")
    else
      changeset
    end
  end
end
