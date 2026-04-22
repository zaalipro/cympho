defmodule Cympho.Documents.IssueDocumentRevision do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Documents.IssueDocument

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_document_revisions" do
    field :body, :string
    field :title, :string
    belongs_to :document, IssueDocument
    timestamps(type: :utc_datetime)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:body, :title, :document_id])
    |> validate_required([:body, :title, :document_id])
  end
end
