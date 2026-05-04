defmodule Cympho.IssueReadStates.IssueReadState do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Users.User
  alias Cympho.Comments.Comment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_read_states" do
    belongs_to :user, User
    belongs_to :issue, Issue
    belongs_to :last_read_comment, Comment
    field :last_read_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def changeset(issue_read_state, attrs) do
    issue_read_state
    |> cast(attrs, [:user_id, :issue_id, :last_read_at, :last_read_comment_id])
    |> validate_required([:user_id, :issue_id, :last_read_at])
    |> unique_constraint(:user_id_issue_id, name: :issue_read_states_user_id_issue_id_index)
  end
end
