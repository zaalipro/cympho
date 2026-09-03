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
    # The effective policy is copied at detection time.  Keeping it on the row
    # makes a restart (or a later config change) unable to silently widen a
    # lineage's retry budget.
    field :policy_snapshot, :map, default: %{}
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
      :policy_snapshot,
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
    |> validate_number(:max_attempts, less_than_or_equal_to: 3)
    |> validate_number(:fingerprint_version, greater_than: 0)
    |> validate_length(:source_fingerprint, is: 64)
    |> validate_format(:source_fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> validate_length(:source_id, max: 255)
    |> validate_snapshot(:source_snapshot, 16_384)
    |> validate_snapshot(:policy_snapshot, 4_096)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:source_run_id)
    |> foreign_key_constraint(:parent_case_id)
    |> foreign_key_constraint(:root_case_id)
    |> unique_constraint(:source_id, name: :recovery_cases_active_source_index)
    |> unique_constraint(:source_fingerprint, name: :recovery_cases_source_history_index)
    |> prepare_changes(&validate_association_scope/1)
  end

  # JSONB is intentionally kept small.  A recovery row is an audit pointer,
  # not a log sink; bounded values also keep scanner queries predictable.
  defp validate_snapshot(changeset, field, max_bytes) do
    value = get_field(changeset, field)

    cond do
      is_nil(value) ->
        changeset

      not is_map(value) ->
        add_error(changeset, field, "must be a map")

      true ->
        case Jason.encode(value) do
          {:ok, encoded} when byte_size(encoded) <= max_bytes -> changeset
          {:ok, _encoded} -> add_error(changeset, field, "is too large")
          {:error, _} -> add_error(changeset, field, "must be JSON encodable")
        end
    end
  end

  defp validate_association_scope(changeset) do
    company_id = get_field(changeset, :company_id)

    if is_binary(company_id) and company_id != "" do
      changeset
      |> validate_same_company(:issue_id, Cympho.Issues.Issue, company_id)
      |> validate_same_company(:agent_id, Cympho.Agents.Agent, company_id)
      |> validate_same_company(:source_run_id, Cympho.HeartbeatEngine.Run, company_id)
      |> validate_same_company(:parent_case_id, __MODULE__, company_id)
      |> validate_same_company(:root_case_id, __MODULE__, company_id)
      |> validate_source_identity()
    else
      add_error(changeset, :company_id, "is required")
    end
  end

  defp validate_same_company(changeset, field, schema, company_id) do
    case get_field(changeset, field) do
      nil ->
        changeset

      id ->
        case changeset.repo.get(schema, id) do
          %{company_id: ^company_id} -> changeset
          nil -> changeset
          _ -> add_error(changeset, field, "must belong to the same company")
        end
    end
  end

  defp validate_source_identity(changeset) do
    source_type = get_field(changeset, :source_type)
    source_id = get_field(changeset, :source_id)
    issue_id = get_field(changeset, :issue_id)
    source_run_id = get_field(changeset, :source_run_id)

    cond do
      source_type == "issue_checkout" and source_id != issue_id ->
        add_error(changeset, :source_id, "must equal issue_id for issue_checkout")

      source_type == "heartbeat_run" and not is_nil(source_run_id) and
          source_id != source_run_id ->
        add_error(changeset, :source_id, "must equal source_run_id for heartbeat_run")

      source_type == "heartbeat_run" and is_binary(source_run_id) ->
        case Ecto.UUID.cast(source_run_id) do
          {:ok, _} ->
            case changeset.repo.get(Run, source_run_id) do
              %Run{issue_id: ^issue_id} -> changeset
              nil -> changeset
              _ -> add_error(changeset, :source_run_id, "must belong to the issue")
            end

          :error ->
            add_error(changeset, :source_run_id, "is invalid")
        end

      true ->
        changeset
    end
  end
end
