defmodule Cympho.BoardApprovals.BoardApprovalVote do
  @moduledoc """
  Individual board member votes on board approval proposals.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.Users.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "board_approval_votes" do
    field :vote, :string
    field :reasoning, :string

    belongs_to :board_approval, BoardApproval
    belongs_to :user, User

    timestamps(type: :utc_datetime)
  end

  def vote_options, do: ["approve", "deny", "abstain"]

  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:vote, :reasoning, :board_approval_id, :user_id])
    |> validate_required([:vote, :board_approval_id, :user_id])
    |> validate_inclusion(:vote, vote_options())
    |> unique_constraint([:board_approval_id, :user_id],
      message: "user has already voted on this proposal"
    )
  end
end
