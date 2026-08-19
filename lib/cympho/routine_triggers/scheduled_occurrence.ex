defmodule Cympho.RoutineTriggers.ScheduledOccurrence do
  use Ecto.Schema

  alias Cympho.RoutineTriggers.RoutineTrigger

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "routine_scheduled_occurrences" do
    field :scheduled_for, :utc_datetime

    belongs_to :trigger, RoutineTrigger

    timestamps(type: :utc_datetime)
  end
end
