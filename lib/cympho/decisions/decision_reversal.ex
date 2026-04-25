defmodule Cympho.Decisions.DecisionReversal do
  @moduledoc """
  Links a reversed decision with its reversing decision.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Decisions.Decision
  alias Cympho.Companies.Company

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "decision_reversals" do
    field :reasoning, :string
    field :actor_type, :string
    field :actor_id, :binary_id
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :original_decision, Decision
    belongs_to :reversing_decision, Decision

    timestamps(type: :utc_datetime)
  end

  def changeset(reversal, attrs) do
    reversal
    |> cast(attrs, [
      :reasoning,
      :actor_type,
      :actor_id,
      :original_decision_id,
      :reversing_decision_id,
      :metadata,
      :company_id
    ])
    |> validate_required([
      :reasoning,
      :actor_type,
      :actor_id,
      :original_decision_id,
      :reversing_decision_id,
      :company_id
    ])
    |> validate_different_decisions()
    |> assoc_constraint(:company)
    |> assoc_constraint(:original_decision)
    |> assoc_constraint(:reversing_decision)
  end

  defp validate_different_decisions(changeset) do
    original_id = get_change(changeset, :original_decision_id)
    reversing_id = get_change(changeset, :reversing_decision_id)

    if original_id && reversing_id && original_id == reversing_id do
      add_error(changeset, :reversing_decision_id, "cannot be the same as original decision")
    else
      changeset
    end
  end
end
