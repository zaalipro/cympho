defmodule Cympho.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Comments.Comment
  alias Cympho.Projects.Project
  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issues" do
    field :title, :string
    field :description, :string
    field :status, Ecto.Enum, values: [:backlog, :todo, :in_progress, :in_review, :done, :blocked], default: :backlog
    field :priority, Ecto.Enum, values: [:low, :medium, :high], default: :medium
    field :lock_version, :integer, default: 0
    field :github_pr_url, :string
    field :assigned_role, Ecto.Enum, values: [:engineer, :cto, :ceo], default: nil

    belongs_to :project, Project
    belongs_to :assignee, Agent, foreign_key: :assignee_id

    has_many :comments, Comment, foreign_key: :issue_id

    many_to_many :blocked_by, Cympho.Issues.Issue,
      join_through: "issue_blockers",
      join_keys: [blocked_issue_id: :id, blocking_issue_id: :id],
      unique: true

    many_to_many :blocks, Cympho.Issues.Issue,
      join_through: "issue_blockers",
      join_keys: [blocking_issue_id: :id, blocked_issue_id: :id],
      unique: true

    timestamps(type: :utc_datetime)
  end

  @github_pr_url_regex ~r/^https:\/\/github\.com\/[\w\-\.]+\/[\w\-\.]+\/pull\/\d+\/?$/

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :priority, :assignee_id, :project_id, :github_pr_url, :assigned_role])
    |> validate_required([:title, :description])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, min: 1)
    |> validate_github_pr_url()
    |> unique_constraint(:identifier, name: :issues_project_id_identifier_index)
  end

  defp validate_github_pr_url(changeset) do
    validate_change(changeset, :github_pr_url, fn _, value ->
      if is_nil(value) or value == "" do
        []
      else
        case Regex.match?(@github_pr_url_regex, value) do
          true -> []
          false -> [github_pr_url: "must be a valid GitHub PR URL (https://github.com/owner/repo/pull/123)"]
        end
      end
    end)
  end

  @doc """
  Returns the role hierarchy rank. Higher number = higher authority.
  Order: designer(1) < product_manager(2) < engineer(3) < cto(4) < ceo(5).
  Matches Cympho.Agents.role_rank/1.
  """
  def role_rank(:designer), do: 1
  def role_rank(:product_manager), do: 2
  def role_rank(:engineer), do: 3
  def role_rank(:cto), do: 4
  def role_rank(:ceo), do: 5

  @doc """
  Returns true if agent_role has authority over (or equal to) required_role.
  """
  def role_authorized?(_agent_role, nil), do: true
  def role_authorized?(agent_role, required_role) when is_atom(agent_role) and is_atom(required_role) do
    role_rank(agent_role) >= role_rank(required_role)
  end

  def status_options, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked]
  def priority_options, do: [:low, :medium, :high]
end
