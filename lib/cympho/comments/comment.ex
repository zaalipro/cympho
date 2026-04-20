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

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :author_type, :author_id, :issue_id])
    |> validate_required([:body, :author_type, :author_id, :issue_id])
    |> validate_length(:body, min: 1)
    |> validate_inclusion(:author_type, ["agent", "user"])
  end
end
