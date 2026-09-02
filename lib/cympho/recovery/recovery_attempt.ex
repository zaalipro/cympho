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
    |> foreign_key_constraint(:recovery_case_id)
    |> unique_constraint([:recovery_case_id, :attempt_no])
  end
end
