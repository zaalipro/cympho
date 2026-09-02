defmodule Cympho.Recovery.RecoveryCase do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Issues.Issue
  alias Cympho.Agents.Agent
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.BoardApprovals.BoardApproval

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @active_states ~w(detected scheduled claimed exhausted escalated)
  @states ~w(detected scheduled claimed recovered exhausted escalated resolved superseded)
  @source_types ~w(heartbeat_run issue_checkout)

  schema "recovery_cases" do
    belongs_to :company, Company
    belongs_to :issue, Issue
    belongs_to :agent, Agent
    belongs_to :source_run, Run
    belongs_to :parent_case, __MODULE__
    belongs_to :root_case, __MODULE__
    has_many :attempts, Cympho.Recovery.RecoveryAttempt
    has_one :board_approval, BoardApproval

    field :source_type, :string
    field :source_id, :string
    field :source_status, :string
    field :source_fingerprint, :string
    field :fingerprint_version, :integer, default: 1
    field :source_snapshot, :map, default: %{}
    field :state, :string, default: "detected"
    field :attempt_count, :integer, default: 0
    field :max_attempts, :integer, default: 3
    field :next_attempt_at, :utc_datetime
    field :claim_token, Ecto.UUID
    field :claimed_at, :utc_datetime
    field :lease_expires_at, :utc_datetime
    field :claimed_by, :string
    field :last_error, :string
    field :last_attempt_at, :utc_datetime
    field :recovered_at, :utc_datetime
    field :exhausted_at, :utc_datetime
    field :escalated_at, :utc_datetime
    field :resolved_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end

  def active_states, do: @active_states
  def states, do: @states
  def source_types, do: @source_types

  def changeset(case_row, attrs) do
    case_row
    |> cast(attrs, [
      :company_id,
      :issue_id,
      :agent_id,
      :source_run_id,
      :parent_case_id,
      :root_case_id,
      :source_type,
      :source_id,
      :source_status,
      :source_fingerprint,
      :fingerprint_version,
      :source_snapshot,
      :state,
      :attempt_count,
      :max_attempts,
      :next_attempt_at,
      :claimed_by,
      :last_error
    ])
    |> validate_required([
      :company_id,
      :issue_id,
      :source_type,
      :source_id,
      :source_fingerprint,
      :fingerprint_version,
      :source_status
    ])
    |> validate_inclusion(:state, states())
    |> validate_inclusion(:source_type, source_types())
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
    |> validate_number(:max_attempts, greater_than: 0)
    |> validate_number(:fingerprint_version, greater_than: 0)
    |> validate_length(:source_fingerprint, is: 64)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:source_run_id)
    |> foreign_key_constraint(:parent_case_id)
    |> foreign_key_constraint(:root_case_id)
    |> unique_constraint(:source_id, name: :recovery_cases_active_source_index)
  end
end
