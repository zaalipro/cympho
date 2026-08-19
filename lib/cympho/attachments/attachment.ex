defmodule Cympho.Attachments.Attachment do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment
  alias Cympho.Agents.Agent

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
    belongs_to :created_by_agent, Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :filename,
      :content_type,
      :file_size,
      :path,
      :issue_id,
      :comment_id,
      :created_by_agent_id
    ])
    |> validate_required([:filename, :content_type, :file_size, :path, :issue_id])
    |> validate_length(:filename, min: 1, max: 255)
    |> validate_file_size()
    |> foreign_key_constraint(:issue_id)
    |> foreign_key_constraint(:comment_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> prepare_changes(&validate_associations/1)
  end

  defp validate_associations(changeset) do
    issue_id = get_field(changeset, :issue_id)

    case issue_company_id(changeset, issue_id) do
      nil ->
        changeset

      company_id ->
        changeset
        |> validate_comment_issue(issue_id)
        |> validate_creator_company(company_id)
    end
  end

  defp validate_comment_issue(changeset, issue_id) do
    case get_field(changeset, :comment_id) do
      nil ->
        changeset

      comment_id ->
        comment_issue_id =
          changeset.repo.one(
            from comment in Comment,
              where: comment.id == ^comment_id,
              select: comment.issue_id
          )

        case comment_issue_id do
          ^issue_id -> changeset
          nil -> changeset
          _other_issue_id -> add_error(changeset, :comment_id, "must belong to the same issue")
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
