defmodule Cympho.Inbox.InboxState do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "inbox_states" do
    field :status, :string, default: "unread"
    field :dismissed_at, :utc_datetime
    field :archived_at, :utc_datetime
    field :read_at, :utc_datetime
    belongs_to :issue, Cympho.Issues.Issue
    belongs_to :agent, Cympho.Agents.Agent

    timestamps(type: :utc_datetime)
  end

  @statuses ~w(unread read dismissed archived)

  def changeset(inbox_state, attrs) do
    inbox_state
    |> cast(attrs, [:status, :dismissed_at, :archived_at, :read_at, :issue_id, :agent_id])
    |> validate_required([:issue_id, :agent_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:issue_agent, name: :inbox_states_issue_id_agent_id_index)
  end

  def dismiss_changeset(inbox_state) do
    inbox_state
    |> change(%{status: "dismissed", dismissed_at: DateTime.utc_now()})
  end

  def archive_changeset(inbox_state) do
    inbox_state
    |> change(%{status: "archived", archived_at: DateTime.utc_now()})
  end

  def read_changeset(inbox_state) do
    inbox_state
    |> change(%{status: "read", read_at: DateTime.utc_now()})
  end

  def restore_changeset(inbox_state) do
    inbox_state
    |> change(%{status: "unread", dismissed_at: nil, archived_at: nil, read_at: nil})
  end
end
