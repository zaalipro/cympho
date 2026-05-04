defmodule Cympho.Issues.Issue do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Comments.Comment
  alias Cympho.Documents.IssueDocument
  alias Cympho.Labels.Label
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Projects.Project
  alias Cympho.Agents.Agent
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "issues" do
    field :title, :string
    field :description, :string
    field :identifier, :string

    field :status, Ecto.Enum,
      values: [:backlog, :todo, :in_progress, :in_review, :done, :blocked, :cancelled],
      default: :backlog

    field :priority, Ecto.Enum, values: [:low, :medium, :high, :critical], default: :medium
    field :lock_version, :integer, default: 0
    field :github_pr_url, :string
    field :execution_state, :map, default: %{}
    field :assigned_role, :string
    field :billing_code, :string
    field :issue_number, :integer
    field :origin_type, :string
    field :origin_id, :string
    field :request_depth, :integer, default: 0
    field :monitor_state, :map, default: %{}
    field :checked_out_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :cancelled_at, :utc_datetime
    field :hidden_at, :utc_datetime
    field :lineage, :map

    belongs_to :project, Project
    belongs_to :company, Cympho.Companies.Company
    belongs_to :goal, Cympho.Goals.Goal
    belongs_to :assignee, Agent, foreign_key: :assignee_id
    belongs_to :assignee_user, Cympho.Users.User, foreign_key: :assignee_user_id
    belongs_to :checkout_run, Cympho.HeartbeatEngine.Run, foreign_key: :checkout_run_id
    belongs_to :created_by_agent, Agent, foreign_key: :created_by_agent_id
    belongs_to :created_by_user, Cympho.Users.User, foreign_key: :created_by_user_id
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
    belongs_to :execution_policy, ExecutionPolicy
    belongs_to :project_workspace, Cympho.Workspaces.ProjectWorkspace
    belongs_to :execution_workspace, Cympho.Workspaces.ExecutionWorkspace

    has_many :comments, Comment, foreign_key: :issue_id
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :documents, IssueDocument, foreign_key: :issue_id
    has_many :work_products, IssueWorkProduct, foreign_key: :issue_id

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
    |> cast(attrs, [
      :title,
      :description,
      :identifier,
      :status,
      :priority,
      :assignee_id,
      :assignee_user_id,
      :checkout_run_id,
      :project_id,
      :company_id,
      :goal_id,
      :github_pr_url,
      :parent_id,
      :execution_policy_id,
      :execution_state,
      :assigned_role,
      :billing_code,
      :issue_number,
      :origin_type,
      :origin_id,
      :request_depth,
      :created_by_agent_id,
      :created_by_user_id,
      :project_workspace_id,
      :execution_workspace_id,
      :monitor_state,
      :lineage,
      :checked_out_at,
      :started_at,
      :completed_at,
      :cancelled_at,
      :hidden_at
    ])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_number(:issue_number, greater_than: 0)
    |> validate_number(:request_depth, greater_than_or_equal_to: 0)
    |> unique_constraint(:identifier, name: :issues_project_id_identifier_index)
    |> unique_constraint(:issue_number, name: :issues_company_id_issue_number_index)
  end

  def status_options, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked, :cancelled]
  def priority_options, do: [:low, :medium, :high, :critical]

  def role_authorized?(_agent_role, nil), do: true

  def role_authorized?(agent_role, required_role) do
    role_rank(agent_role) >= role_rank(required_role)
  end

  def role_rank(:ceo), do: 3
  def role_rank(:cto), do: 2
  def role_rank(:engineer), do: 1
  def role_rank(:product_manager), do: 1
  def role_rank(:designer), do: 1
  def role_rank(_), do: 0
end

# TEST MARKER
