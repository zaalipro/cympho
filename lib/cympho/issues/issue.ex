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

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :priority, :assignee_id, :project_id, :github_pr_url, :assigned_role])
    |> validate_required([:title, :description])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, min: 1)
    |> unique_constraint(:identifier, name: :issues_project_id_identifier_index)
  end

  @doc """
  Returns the role hierarchy rank. Higher number = higher authority.
  """
  def role_rank(:engineer), do: 1
  def role_rank(:cto), do: 2
  def role_rank(:ceo), do: 3

  @doc """
  Returns true if agent_role has authority over (or equal to) required_role.
  """
  def role_authorized?(agent_role, required_role) when is_atom(agent_role) and is_atom(required_role) do
    role_rank(agent_role) >= role_rank(required_role)
  end
  def role_authorized?(_agent_role, nil), do: true

  def status_options, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked]
  def priority_options, do: [:low, :medium, :high]
end
