defmodule Cympho.Comments.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comments" do
    field :body, :string
    field :author_type, :string
    field :author_id, :string

    belongs_to :issue, Issue

    # Microseconds, unlike the :utc_datetime used elsewhere. Several comments
    # are written inside a single action batch, and the receipt audit that gates
    # delivery picks "the newest meaningful agent comment" — at second
    # precision those comments tie and the gate's verdict depended on the order
    # Postgres returned rows in.
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :author_type, :author_id, :issue_id])
    |> validate_required([:body, :author_type, :author_id, :issue_id])
    |> validate_length(:body, min: 1)
    |> validate_inclusion(:author_type, ["agent", "user", "system"])
  end
end
