defmodule Cympho.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Comments.Comment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issues" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:open, :in_progress, :closed], default: :open
    field :priority, Ecto.Enum, values: [:low, :medium, :high], default: :medium

    has_many :comments, Comment, foreign_key: :issue_id

    timestamps(type: :utc_datetime)
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :priority])
    |> validate_required([:title, :description])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, min: 1)
  end

  def status_options, do: [:open, :in_progress, :closed]
  def priority_options, do: [:low, :medium, :high]
end
