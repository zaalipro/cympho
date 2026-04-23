defmodule Cympho.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment

  @max_file_size 10 * 1024 * 1024

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "attachments" do
    field :filename, :string
    field :content_type, :string
    field :file_size, :integer
    field :path, :string

    belongs_to :issue, Issue
    belongs_to :comment, Comment

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :file_size, :path, :issue_id, :comment_id])
    |> validate_required([:filename, :content_type, :file_size, :path, :issue_id])
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_file_size()
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:comment_id)
  end

  defp validate_file_size(changeset) do
    validate_change(changeset, :file_size, fn :file_size, size ->
      if size > @max_file_size do
        [file_size: "must be less than 10MB"]
      else
        []
      end
    end)
  end

  def max_file_size, do: @max_file_size
end
