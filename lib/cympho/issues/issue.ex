defmodule Cympho.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Comments.Comment
  alias Cympho.Labels.Label
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

    belongs_to :project, Project
    belongs_to :assignee, Agent, foreign_key: :assignee_id
    belongs_to :parent, __MODULE__, foreign_key: :parent_id

    has_many :comments, Comment, foreign_key: :issue_id
    has_many :children, __MODULE__, foreign_key: :parent_id

    many_to_many :blocked_by, Cympho.Issues.Issue,
      join_through: "issue_blockers",
      join_keys: [blocked_issue_id: :id, blocking_issue_id: :id],
      unique: true

    many_to_many :blocks, Cympho.Issues.Issue,
      join_through: "issue_blockers",
      join_keys: [blocking_issue_id: :id, blocked_issue_id: :id],
      unique: true

    many_to_many :labels, Label, join_through: "issue_labels", unique: true

    timestamps(type: :utc_datetime)
  end

  def changeset(issue, attrs) do
    issue
    |> cast(attrs, [:title, :description, :status, :priority, :assignee_id, :project_id, :github_pr_url, :parent_id])
    |> validate_required([:title, :description])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_length(:description, min: 1)
    |> unique_constraint(:identifier, name: :issues_project_id_identifier_index)
  end

  def status_options, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked]
  def priority_options, do: [:low, :medium, :high]
end
