defmodule Cympho.RoutineTriggers.RoutineTrigger do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Repo
  alias Cympho.Routines.Routine
  alias Cympho.RoutineTriggers.RoutineRun
  alias Cympho.Secrets.Secret

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "routine_triggers" do
    field :type, :string
    field :cron_expression, :string
    field :public_id, :string
    field :secret_hash, :string
    field :signing_mode, :string
    field :replay_window_seconds, :integer, default: 300
    field :enabled, :boolean, default: true

    belongs_to :routine, Routine
    belongs_to :secret, Secret
    has_many :runs, RoutineRun, foreign_key: :trigger_id

    timestamps(type: :utc_datetime)
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :type,
      :cron_expression,
      :public_id,
      :secret_hash,
      :signing_mode,
      :replay_window_seconds,
      :enabled,
      :routine_id,
      :secret_id
    ])
    |> validate_required([:type, :routine_id])
    |> validate_inclusion(:type, ["schedule", "webhook"])
    |> validate_inclusion(:signing_mode, ["hmac_sha256", "legacy_bearer"])
    |> validate_number(:replay_window_seconds,
      greater_than_or_equal_to: 30,
      less_than_or_equal_to: 3_600
    )
    |> validate_schedule_fields()
    |> validate_webhook_fields()
    |> validate_secret_company()
    |> assoc_constraint(:routine)
    |> assoc_constraint(:secret)
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
      |> validate_required([:public_id, :secret_hash, :signing_mode])
      |> validate_hmac_secret()
    else
      changeset
    end
  end

  defp validate_hmac_secret(changeset) do
    if get_field(changeset, :signing_mode) == "hmac_sha256" do
      validate_required(changeset, [:secret_id, :replay_window_seconds])
    else
      changeset
    end
  end

  defp validate_secret_company(changeset) do
    routine_id = get_field(changeset, :routine_id)
    secret_id = get_field(changeset, :secret_id)

    if is_binary(routine_id) and is_binary(secret_id) do
      routine = Routine |> Repo.get(routine_id) |> maybe_preload_routine()
      secret = Repo.get(Secret, secret_id)

      if routine_company_id(routine) == secret_company_id(secret),
        do: changeset,
        else: add_error(changeset, :secret_id, "is not in the routine company")
    else
      changeset
    end
  end

  defp maybe_preload_routine(nil), do: nil
  defp maybe_preload_routine(routine), do: Repo.preload(routine, [:agent, :project])

  defp routine_company_id(%Routine{company_id: id}) when is_binary(id), do: id
  defp routine_company_id(%Routine{agent: %{company_id: id}}) when is_binary(id), do: id
  defp routine_company_id(%Routine{project: %{company_id: id}}) when is_binary(id), do: id
  defp routine_company_id(_routine), do: nil

  defp secret_company_id(%Secret{company_id: id}), do: id
  defp secret_company_id(_secret), do: nil

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
