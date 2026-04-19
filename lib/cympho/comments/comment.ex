defmodule Cympho.Comments.Comment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "comments" do
    field :body, :string
    field :author, :string

    belongs_to :issue, Issue

    timestamps(type: :utc_datetime)
  end

  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:body, :author, :issue_id])
    |> validate_required([:body, :author, :issue_id])
    |> validate_length(:body, min: 1)
    |> validate_length(:author, min: 1, max: 100)
  end
end
