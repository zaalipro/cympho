defmodule Cympho.RoutineTriggers.RoutineRun do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Routines.Routine
  alias Cympho.RoutineTriggers.RoutineTrigger

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routine_runs" do
    field :status, :string, default: "pending"
    field :trigger_type, :string
    field :triggered_at, :utc_datetime
    field :completed_at, :utc_datetime

    belongs_to :issue, Issue
    belongs_to :routine, Routine
    belongs_to :trigger, RoutineTrigger

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :status,
      :trigger_type,
      :triggered_at,
      :completed_at,
      :issue_id,
      :routine_id,
      :trigger_id
    ])
    |> validate_required([:trigger_type, :triggered_at, :routine_id])
    |> validate_inclusion(:status, ["pending", "running", "completed", "failed"])
    |> validate_inclusion(:trigger_type, ["schedule", "webhook", "manual"])
    |> assoc_constraint(:routine)
  end
end
