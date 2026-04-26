defmodule Cympho.Documents.IssueDocumentRevision do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Documents.IssueDocument

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_document_revisions" do
    field :body, :string
    field :title, :string
    field :revision_number, :integer
    field :change_summary, :string
    field :author_id, :binary_id
    field :author_type, :string, default: "agent"
    field :parent_revision_number, :integer
    belongs_to :parent, __MODULE__
    belongs_to :document, IssueDocument
    timestamps(type: :utc_datetime)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [:body, :title, :document_id, :revision_number, :change_summary, :author_id, :author_type, :parent_id, :parent_revision_number])
    |> validate_required([:body, :title, :document_id])
    |> validate_inclusion(:author_type, ["agent", "user", "system"])
    |> validate_number(:revision_number, greater_than: 0)
  end
end
