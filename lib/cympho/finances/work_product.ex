defmodule Cympho.Finances.WorkProduct do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Issues.Issue
  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "work_products" do
    belongs_to :issue, Issue
    belongs_to :agent, Agent

    field :name, :string
    field :content_type, :string
    field :content, :string
    field :file_path, :string

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def changeset(work_product, attrs) do
    work_product
    |> cast(attrs, [
      :issue_id,
      :agent_id,
      :name,
      :content_type,
      :content,
      :file_path,
      :metadata
    ])
    |> validate_required([:issue_id, :name, :content_type])
    |> validate_length(:name, min: 1, max: 255)
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:agent_id)
  end
end
