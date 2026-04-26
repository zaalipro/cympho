defmodule Cympho.Documents.IssueDocumentRevision do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Documents.IssueDocument
  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issue_document_revisions" do
    field :body, :string
    field :title, :string
    field :revision_number, :integer
    field :format, :string, default: "markdown"
    field :change_summary, :string
    field :created_by_user_id, :string

    belongs_to :document, IssueDocument
    belongs_to :base_revision, __MODULE__
    belongs_to :created_by_agent, Agent, foreign_key: :created_by_agent_id

    timestamps(type: :utc_datetime)
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :body,
      :title,
      :document_id,
      :revision_number,
      :format,
      :base_revision_id,
      :change_summary,
      :created_by_agent_id,
      :created_by_user_id
    ])
    |> validate_required([:body, :title, :document_id, :revision_number])
    |> validate_inclusion(:format, ["markdown", "text"])
    |> unique_constraint([:document_id, :revision_number],
      name: :issue_document_revisions_unique_revision_number
    )
    |> assoc_constraint(:document)
  end
end
