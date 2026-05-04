defmodule Cympho.Issues.IssueThreadInteraction do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Agents.Agent
  alias Cympho.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_thread_interactions" do
    field :kind, Ecto.Enum, values: [:suggest_tasks, :ask_user_questions, :request_confirmation]

    field :payload, :map, default: %{}

    field :status, Ecto.Enum,
      values: [:pending, :accepted, :rejected, :responded],
      default: :pending

    belongs_to :issue, Issue
    belongs_to :created_by_agent, Agent, foreign_key: :created_by_agent_id
    belongs_to :resolved_by_user, User, foreign_key: :resolved_by_user_id

    field :resolved_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [
      :issue_id,
      :kind,
      :payload,
      :status,
      :created_by_agent_id,
      :resolved_by_user_id,
      :resolved_at
    ])
    |> validate_required([:issue_id, :kind])
    |> validate_inclusion(:kind, [:suggest_tasks, :ask_user_questions, :request_confirmation])
    |> validate_inclusion(:status, [:pending, :accepted, :rejected, :responded])
    |> assoc_constraint(:issue)
  end

  def resolve_changeset(interaction, attrs) do
    interaction
    |> cast(attrs, [:status, :resolved_by_user_id, :resolved_at, :payload])
    |> validate_required([:status, :resolved_by_user_id, :resolved_at])
    |> validate_inclusion(:status, [:accepted, :rejected, :responded])
  end

  def kind_options, do: [:suggest_tasks, :ask_user_questions, :request_confirmation]
  def status_options, do: [:pending, :accepted, :rejected, :responded]
end
