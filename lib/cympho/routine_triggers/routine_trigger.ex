defmodule Cympho.RoutineTriggers.RoutineTrigger do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Routines.Routine
  alias Cympho.RoutineTriggers.RoutineRun

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routine_triggers" do
    field :type, :string
    field :cron_expression, :string
    field :public_id, :string
    field :secret_hash, :string
    field :enabled, :boolean, default: true

    belongs_to :routine, Routine
    has_many :runs, RoutineRun, foreign_key: :trigger_id

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :cron_expression, :public_id, :secret_hash, :enabled, :routine_id])
    |> validate_required([:type, :routine_id])
    |> validate_inclusion(:type, ["schedule", "webhook"])
    |> validate_schedule_fields()
    |> validate_webhook_fields()
    |> assoc_constraint(:routine)
    |> unique_constraint(:public_id)
  end

  defp validate_schedule_fields(changeset) do
    if get_field(changeset, :type) == "schedule" do
      changeset
      |> validate_required([:cron_expression])
      |> validate_cron_expression()
    else
      changeset
    end
  end

  defp validate_webhook_fields(changeset) do
    if get_field(changeset, :type) == "webhook" do
      changeset
      |> validate_required([:public_id, :secret_hash])
    else
      changeset
    end
  end

  defp validate_cron_expression(changeset) do
    case get_field(changeset, :cron_expression) do
      nil ->
        changeset

      expr ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _} -> changeset
          {:error, reason} -> add_error(changeset, :cron_expression, "invalid cron: #{reason}")
        end
    end
  end
end
