defmodule Cympho.Routines.Routine do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routines" do
    field :name, :string
    field :description, :string

    field :status, Ecto.Enum,
      values: [:active, :paused, :archived],
      default: :active

    field :concurrency_policy, Ecto.Enum,
      values: [:coalesce_if_active, :skip_if_active, :always_enqueue],
      default: :coalesce_if_active

    field :catch_up_policy, Ecto.Enum,
      values: [:skip_missed, :enqueue_missed_with_cap],
      default: :skip_missed

    field :priority, Ecto.Enum,
      values: [:critical, :high, :medium, :low],
      default: :medium

    belongs_to :agent, Agent
    belongs_to :project, Project

    has_many :triggers, Cympho.RoutineTriggers.RoutineTrigger, foreign_key: :routine_id
    has_many :runs, Cympho.RoutineTriggers.RoutineRun, foreign_key: :routine_id

    timestamps(type: :utc_datetime)
  end

  def changeset(routine, attrs) do
    routine
    |> cast(attrs, [
      :name,
      :description,
      :status,
      :concurrency_policy,
      :catch_up_policy,
      :priority,
      :agent_id,
      :project_id
    ])
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 200)
  end
end
