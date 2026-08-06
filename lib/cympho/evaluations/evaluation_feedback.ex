defmodule Cympho.Evaluations.EvaluationFeedback do
  @moduledoc """
  Append-only owner feedback on an evaluation run (or single result).

  Votes connect outcomes back to instruction-improvement review without mutating
  the immutable run/result provenance.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Evaluations.{EvaluationResult, EvaluationRun}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @votes ~w(agree disagree neutral)
  @actor_types ~w(user agent system)

  schema "evaluation_feedback" do
    field :vote, :string
    field :reason, :string
    field :actor_type, :string, default: "user"
    field :actor_id, :binary_id

    belongs_to :company, Company
    belongs_to :run, EvaluationRun
    belongs_to :result, EvaluationResult

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def votes, do: @votes
  def actor_types, do: @actor_types

  def changeset(feedback, attrs) do
    feedback
    |> cast(attrs, [
      :company_id,
      :run_id,
      :result_id,
      :vote,
      :reason,
      :actor_type,
      :actor_id
    ])
    |> validate_required([:company_id, :run_id, :vote, :actor_type])
    |> validate_inclusion(:vote, @votes)
    |> validate_inclusion(:actor_type, @actor_types)
    |> validate_length(:reason, max: 4000)
    |> assoc_constraint(:company)
    |> assoc_constraint(:run)
    |> assoc_constraint(:result)
  end
end
