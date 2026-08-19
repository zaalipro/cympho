defmodule Cympho.WorkProducts.IssueWorkProduct do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

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
    |> prepare_changes(&validate_associations/1)
  end

  def update_changeset(work_product, attrs) do
    work_product
    |> cast(attrs, [:attachment_id, :kind, :title, :description, :payload, :url, :metadata])
    |> validate_required([:issue_id, :kind, :title])
    |> validate_inclusion(:kind, @kinds)
    |> validate_length(:title, min: 1, max: 255)
    |> foreign_key_constraint(:attachment_id)
    |> prepare_changes(&validate_associations/1)
  end

  defp validate_associations(changeset) do
    issue_id = get_field(changeset, :issue_id)

    case issue_company_id(changeset, issue_id) do
      nil ->
        changeset

      company_id ->
        changeset
        |> validate_attachment_issue(issue_id)
        |> validate_creator_company(company_id)
    end
  end

  defp validate_attachment_issue(changeset, issue_id) do
    case get_field(changeset, :attachment_id) do
      nil ->
        changeset

      attachment_id ->
        attachment_issue_id =
          changeset.repo.one(
            from attachment in Attachment,
              where: attachment.id == ^attachment_id,
              select: attachment.issue_id
          )

        case attachment_issue_id do
          ^issue_id ->
            changeset

          nil ->
            changeset

          _other_issue_id ->
            add_error(changeset, :attachment_id, "must belong to the same issue")
        end
    end
  end

  defp validate_creator_company(changeset, company_id) do
    case get_field(changeset, :created_by_agent_id) do
      nil ->
        changeset

      agent_id ->
        agent_company_id =
          changeset.repo.one(
            from agent in Agent,
              where: agent.id == ^agent_id,
              select: agent.company_id
          )

        case agent_company_id do
          ^company_id ->
            changeset

          nil ->
            changeset

          _other_company_id ->
            add_error(changeset, :created_by_agent_id, "must belong to the issue company")
        end
    end
  end

  defp issue_company_id(_changeset, nil), do: nil

  defp issue_company_id(changeset, issue_id) do
    changeset.repo.one(
      from issue in Issue,
        where: issue.id == ^issue_id,
        select: issue.company_id
    )
  end

  def kind_options, do: @kinds
end
