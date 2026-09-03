defmodule Cympho.Recovery.RecoveryAttempt do
  use Ecto.Schema
  import Ecto.Changeset
  alias Cympho.Recovery.RecoveryCase

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(claimed succeeded failed skipped)
  schema "recovery_attempts" do
    belongs_to :recovery_case, RecoveryCase
    field :attempt_no, :integer
    field :status, :string, default: "claimed"
    field :action, :string
    field :source_fingerprint, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :next_retry_at, :utc_datetime
    field :error_reason, :string
    field :node, :string
    field :metadata, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :recovery_case_id,
      :attempt_no,
      :status,
      :action,
      :source_fingerprint,
      :started_at,
      :completed_at,
      :next_retry_at,
      :error_reason,
      :node,
      :metadata
    ])
    |> validate_required([:recovery_case_id, :attempt_no, :status, :action, :source_fingerprint])
    |> validate_inclusion(:status, statuses())
    |> validate_number(:attempt_no, greater_than: 0)
    |> validate_length(:source_fingerprint, is: 64)
    |> validate_format(:source_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:action, max: 64)
    |> validate_length(:error_reason, max: 255)
    |> validate_length(:node, max: 255)
    |> validate_metadata()
    |> foreign_key_constraint(:recovery_case_id)
    |> unique_constraint([:recovery_case_id, :attempt_no])
  end

  defp validate_metadata(changeset) do
    metadata = get_field(changeset, :metadata)

    cond do
      is_nil(metadata) ->
        changeset

      not is_map(metadata) ->
        add_error(changeset, :metadata, "must be a map")

      true ->
        case Jason.encode(metadata) do
          {:ok, encoded} when byte_size(encoded) <= 8_192 -> changeset
          {:ok, _encoded} -> add_error(changeset, :metadata, "is too large")
          {:error, _} -> add_error(changeset, :metadata, "must be JSON encodable")
        end
    end
  end
end
