defmodule Cympho.Evaluations.EvaluationRun do
  @moduledoc """
  Immutable company-scoped evaluation run with redacted provenance.

  Provenance (model/prompt/skill hashes) is set at create time and never
  rewritten. Status may advance pending → running → completed|failed once.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Evaluations.EvaluationSuite

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed)
  @triggers ~w(manual rerun scheduled)

  schema "evaluation_runs" do
    field :status, :string, default: "pending"
    field :trigger, :string, default: "manual"
    field :provenance, :map, default: %{}
    field :summary, :map, default: %{}
    field :redacted_metadata, :map, default: %{}
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :company, Company
    belongs_to :suite, EvaluationSuite
    belongs_to :parent_run, __MODULE__

    has_many :results, Cympho.Evaluations.EvaluationResult, foreign_key: :run_id
    has_many :feedback, Cympho.Evaluations.EvaluationFeedback, foreign_key: :run_id

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
  def triggers, do: @triggers

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :company_id,
      :suite_id,
      :status,
      :trigger,
      :parent_run_id,
      :provenance,
      :summary,
      :redacted_metadata,
      :started_at,
      :completed_at
    ])
    |> validate_required([:company_id, :suite_id, :status, :trigger, :provenance])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:trigger, @triggers)
    |> assoc_constraint(:company)
    |> assoc_constraint(:suite)
  end

  @doc """
  Advances status only. Provenance and identity fields are not castable.
  """
  def status_changeset(run, attrs) do
    run
    |> cast(attrs, [:status, :summary, :completed_at, :started_at, :redacted_metadata])
    |> validate_required([:status])
    |> validate_inclusion(:status, @statuses)
    |> validate_status_transition(run.status)
  end

  defp validate_status_transition(changeset, from) do
    to = get_field(changeset, :status)

    allowed =
      case from do
        "pending" -> ~w(running completed failed)
        "running" -> ~w(completed failed)
        "completed" -> []
        "failed" -> []
        _ -> @statuses
      end

    if to == from or to in allowed do
      changeset
    else
      add_error(changeset, :status, "cannot transition from #{from} to #{to}")
    end
  end
end
