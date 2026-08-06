defmodule Cympho.Evaluations.EvaluationResult do
  @moduledoc """
  Immutable per-case outcome for an evaluation run.

  Results are insert-only. Traces stored in `redacted_trace` must already have
  secret-like values scrubbed by the Evaluations context.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Evaluations.{EvaluationRun, EvaluationSuite}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "evaluation_results" do
    field :case_key, :string
    field :case_label, :string
    field :kind, :string
    field :expectation, :string
    field :passed, :boolean, default: false
    field :audit_status, :string
    field :audit_summary, :string
    field :gap_fields, {:array, :string}, default: []
    field :validated_fields, {:array, :string}, default: []
    field :redacted_trace, :map, default: %{}
    field :score, :integer

    belongs_to :company, Company
    belongs_to :run, EvaluationRun
    belongs_to :suite, EvaluationSuite

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(result, attrs) do
    result
    |> cast(attrs, [
      :company_id,
      :run_id,
      :suite_id,
      :case_key,
      :case_label,
      :kind,
      :expectation,
      :passed,
      :audit_status,
      :audit_summary,
      :gap_fields,
      :validated_fields,
      :redacted_trace,
      :score
    ])
    |> validate_required([:company_id, :run_id, :suite_id, :case_key, :passed])
    |> unique_constraint([:run_id, :case_key])
    |> assoc_constraint(:company)
    |> assoc_constraint(:run)
    |> assoc_constraint(:suite)
  end
end
