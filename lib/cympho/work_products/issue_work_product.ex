defmodule Cympho.WorkProducts.IssueWorkProduct do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Agents.Agent
  alias Cympho.Attachments.Attachment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(code_change document url artifact other)

  schema "issue_work_products" do
    belongs_to :issue, Issue
    belongs_to :created_by_agent, Agent, foreign_key: :created_by_agent_id
    belongs_to :attachment, Attachment

    field :kind, :string
    field :title, :string
    field :description, :string
    field :payload, :map, default: %{}
    field :url, :string
    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(work_product, attrs) do
    work_product
    |> cast(attrs, [
      :issue_id,
      :created_by_agent_id,
      :attachment_id,
      :kind,
      :title,
      :description,
      :payload,
      :url,
      :metadata
    ])
    |> validate_required([:issue_id, :kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, min: 1, max: 255)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:attachment_id)
  end

  def kind_options, do: @kinds
end
