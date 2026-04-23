defmodule Cympho.Documents.IssueDocument do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Documents.IssueDocumentRevision

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_documents" do
    field :key, :string
    field :title, :string
    field :format, :string, default: "markdown"
    field :body, :string, default: ""
    belongs_to :issue, Issue
    has_many :revisions, IssueDocumentRevision, foreign_key: :document_id
    timestamps(type: :utc_datetime)
  end

  def changeset(document, attrs) do
    document
    |> cast(attrs, [:key, :title, :format, :body, :issue_id])
    |> validate_required([:key, :title, :issue_id])
    |> validate_length(:key, min: 1, max: 100)
    |> validate_length(:title, min: 1, max: 255)
    |> validate_inclusion(:format, ["markdown", "text"])
    |> unique_constraint([:issue_id, :key])
  end
end
