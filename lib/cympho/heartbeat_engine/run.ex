defmodule Cympho.HeartbeatEngine.Run do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Agents.Agent
  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "heartbeat_runs" do
    belongs_to :agent, Agent
    belongs_to :issue, Issue

    field :status, :string, default: "pending"
    field :adapter, :string, default: "claude_local"
    field :workspace_path, :string

    field :budget_allocated, :decimal, default: Decimal.new("0")
    field :budget_used, :decimal, default: Decimal.new("0")

    field :input_tokens, :integer, default: 0
    field :output_tokens, :integer, default: 0
    field :cost_usd, :decimal, default: Decimal.new("0")

    field :continuation_summary, :string
    field :session_state, :map, default: %{}
    field :run_metadata, :map, default: %{}

    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :last_heartbeat_at, :utc_datetime

    field :error_reason, :string
    field :retry_count, :integer, default: 0

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(pending running completed failed cancelled)
  def statuses, do: @statuses

  def create_changeset(run, attrs) do
    run
    |> cast(attrs, [
      :agent_id,
      :issue_id,
      :status,
      :adapter,
      :workspace_path,
      :budget_allocated,
      :continuation_summary,
      :session_state,
      :run_metadata
    ])
    |> validate_required([:agent_id, :issue_id, :adapter])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:agent)
    |> assoc_constraint(:issue)
  end

  def start_changeset(run, attrs) do
    now = DateTime.utc_now()

    run
    |> cast(attrs, [:workspace_path, :budget_allocated, :run_metadata])
    |> put_change(:status, "running")
    |> put_change(:started_at, now)
    |> put_change(:last_heartbeat_at, now)
    |> validate_required([:workspace_path])
  end

  def complete_changeset(run, attrs) do
    now = DateTime.utc_now()

    run
    |> cast(attrs, [
      :budget_used,
      :input_tokens,
      :output_tokens,
      :cost_usd,
      :continuation_summary,
      :session_state,
      :run_metadata
    ])
    |> put_change(:status, "completed")
    |> put_change(:completed_at, now)
    |> put_change(:last_heartbeat_at, now)
  end

  def fail_changeset(run, attrs) do
    now = DateTime.utc_now()

    run
    |> cast(attrs, [:error_reason, :session_state, :run_metadata])
    |> put_change(:status, "failed")
    |> put_change(:completed_at, now)
    |> put_change(:last_heartbeat_at, now)
  end

  def heartbeat_changeset(run) do
    now = DateTime.utc_now()

    run
    |> change(%{last_heartbeat_at: now})
  end
end
