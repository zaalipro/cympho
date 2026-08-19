defmodule Cympho.Issues.Issue do
  @moduledoc """
  Issue schema.

  ## `monitor_state["routing"]` shape

  When `Cympho.Routing.classify_and_persist/1` resolves an issue's role, it
  records provenance under `monitor_state["routing"]` so the system can tell
  whether the role came from the LLM, the keyword router, or a fallback. The
  shape is:

      %{
        "source"        => "llm" | "keyword" | "fallback",
        "classified_at" => iso8601 string,
        "model"         => string | nil
      }

  Re-classification is gated on `monitor_state["routing"]["source"] == "llm"`
  so manually edited `assigned_role` values are not clobbered.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Cympho.Comments.Comment
  alias Cympho.Documents.IssueDocument
  alias Cympho.Labels.Label
  alias Cympho.WorkProducts.IssueWorkProduct
  alias Cympho.Projects.Project
  alias Cympho.Agents.Agent
  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.Workspaces.{ExecutionWorkspace, ProjectWorkspace}

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

    field :work_mode, Ecto.Enum,
      values: [:standard, :planning, :ask],
      default: :standard

    field :lock_version, :integer, default: 0
    field :github_pr_url, :string
    field :github_pr_number, :integer
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
    field :due_on, :date
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
    belongs_to :last_reviewer, Agent, foreign_key: :last_reviewer_id

    # Ordered so a preload cannot hand the receipt audit its comments in
    # whatever order the planner produced.
    has_many :comments, Comment, foreign_key: :issue_id, preload_order: [asc: :inserted_at]
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

    many_to_many :labels, Label, join_through: "issue_labels", unique: true, on_replace: :delete

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
      :work_mode,
      :assignee_id,
      :assignee_user_id,
      :checkout_run_id,
      :project_id,
      :company_id,
      :goal_id,
      :github_pr_url,
      :github_pr_number,
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
      :hidden_at,
      :due_on,
      :last_reviewer_id
    ])
    |> validate_required([:title])
    |> validate_length(:title, min: 1, max: 255)
    |> validate_number(:issue_number, greater_than: 0)
    |> validate_number(:request_depth, greater_than_or_equal_to: 0)
    |> validate_inclusion(:work_mode, work_mode_options())
    |> unique_constraint(:identifier, name: :issues_project_id_identifier_index)
    |> unique_constraint(:issue_number, name: :issues_company_id_issue_number_index)
    |> foreign_key_constraint(:company_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:goal_id)
    |> foreign_key_constraint(:assignee_id)
    |> foreign_key_constraint(:assignee_user_id)
    |> foreign_key_constraint(:checkout_run_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:created_by_user_id)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:execution_policy_id)
    |> foreign_key_constraint(:project_workspace_id)
    |> foreign_key_constraint(:execution_workspace_id)
    |> foreign_key_constraint(:last_reviewer_id)
    |> prepare_changes(&validate_association_scope/1)
  end

  defp validate_association_scope(changeset) do
    company_id = get_field(changeset, :company_id)

    changeset
    |> validate_company_immutable(company_id)
    |> validate_same_company(:project_id, Project, company_id)
    |> validate_same_company(:goal_id, Cympho.Goals.Goal, company_id)
    |> validate_same_company(:assignee_id, Agent, company_id)
    |> validate_same_company(:created_by_agent_id, Agent, company_id)
    |> validate_same_company(:last_reviewer_id, Agent, company_id)
    |> validate_same_company(:parent_id, __MODULE__, company_id)
    |> validate_same_company(:execution_policy_id, ExecutionPolicy, company_id)
    |> validate_user_membership(:assignee_user_id, company_id)
    |> validate_user_membership(:created_by_user_id, company_id)
    |> validate_project_workspace(company_id)
    |> validate_execution_workspace(company_id)
    |> validate_checkout_run(company_id)
  end

  defp validate_company_immutable(
         %{data: %{id: id, company_id: old_company_id}} = changeset,
         new_company_id
       )
       when not is_nil(id) and is_binary(old_company_id) and old_company_id != new_company_id,
       do: add_error(changeset, :company_id, "cannot be changed")

  defp validate_company_immutable(changeset, _company_id), do: changeset

  # Company-less legacy rows remain readable/updateable, but every scoped row
  # must keep all tenant-bearing references inside its own company.
  defp validate_same_company(changeset, _field, _schema, company_id)
       when not is_binary(company_id),
       do: changeset

  defp validate_same_company(changeset, field, schema, company_id) do
    case get_field(changeset, field) do
      nil ->
        changeset

      id ->
        case changeset.repo.get(schema, id) do
          %{company_id: ^company_id} -> changeset
          nil -> changeset
          _ -> add_error(changeset, field, "must belong to the same company")
        end
    end
  end

  defp validate_user_membership(changeset, _field, company_id)
       when not is_binary(company_id),
       do: changeset

  defp validate_user_membership(changeset, field, company_id) do
    case get_field(changeset, field) do
      nil ->
        changeset

      user_id ->
        member? =
          changeset.repo.exists?(
            from membership in Cympho.Companies.CompanyMembership,
              where: membership.user_id == ^user_id and membership.company_id == ^company_id
          )

        if member?, do: changeset, else: add_error(changeset, field, "must belong to the company")
    end
  end

  defp validate_project_workspace(changeset, company_id) when is_binary(company_id) do
    project_id = get_field(changeset, :project_id)

    case get_field(changeset, :project_workspace_id) do
      nil ->
        changeset

      workspace_id ->
        case changeset.repo.get(ProjectWorkspace, workspace_id) do
          %ProjectWorkspace{company_id: ^company_id, project_id: workspace_project_id}
          when workspace_project_id == project_id ->
            changeset

          nil ->
            changeset

          _ ->
            add_error(
              changeset,
              :project_workspace_id,
              "must belong to the issue company and project"
            )
        end
    end
  end

  defp validate_project_workspace(changeset, _company_id), do: changeset

  defp validate_execution_workspace(changeset, company_id) when is_binary(company_id) do
    project_id = get_field(changeset, :project_id)

    case get_field(changeset, :execution_workspace_id) do
      nil ->
        changeset

      workspace_id ->
        case changeset.repo.get(ExecutionWorkspace, workspace_id) do
          %ExecutionWorkspace{company_id: ^company_id, project_id: workspace_project_id}
          when workspace_project_id == project_id ->
            changeset

          nil ->
            changeset

          _ ->
            add_error(
              changeset,
              :execution_workspace_id,
              "must belong to the issue company and project"
            )
        end
    end
  end

  defp validate_execution_workspace(changeset, _company_id), do: changeset

  defp validate_checkout_run(changeset, company_id) when is_binary(company_id) do
    case get_field(changeset, :checkout_run_id) do
      nil ->
        changeset

      run_id ->
        issue_id = changeset.data.id

        case changeset.repo.get(Run, run_id) do
          %Run{company_id: ^company_id, issue_id: ^issue_id} -> changeset
          nil -> changeset
          _ -> add_error(changeset, :checkout_run_id, "must belong to this issue")
        end
    end
  end

  defp validate_checkout_run(changeset, _company_id), do: changeset

  def status_options, do: [:backlog, :todo, :in_progress, :in_review, :done, :blocked, :cancelled]
  def priority_options, do: [:low, :medium, :high, :critical]
  def work_mode_options, do: [:standard, :planning, :ask]

  @doc """
  Builds the canonical GitHub PR URL for an issue. Prefers the new
  `github_pr_number` + project's `repo_url` combination (so the URL
  follows project repo moves automatically); falls back to the legacy
  free-form `github_pr_url` field for issues created before the
  migration.
  """
  def pr_url(%__MODULE__{github_pr_number: nil} = issue, _project), do: issue.github_pr_url

  def pr_url(%__MODULE__{github_pr_number: n}, %{repo_url: url})
      when is_integer(n) and is_binary(url) and url != "" do
    "#{String.trim_trailing(url, "/")}/pull/#{n}"
  end

  def pr_url(%__MODULE__{} = issue, _project), do: issue.github_pr_url

  def role_authorized?(_agent_role, nil), do: true

  def role_authorized?(agent_role, required_role) do
    role_rank(agent_role) >= role_rank(required_role)
  end

  def role_rank(:ceo), do: 5
  def role_rank(:cto), do: 4
  def role_rank(role) when role in [:engineer, :release_engineer, :qa_engineer], do: 3
  def role_rank(:product_manager), do: 2

  def role_rank(role)
      when role in [
             :designer,
             :researcher,
             :marketer,
             :content_strategist,
             :sales_development,
             :customer_support
           ],
      do: 1

  def role_rank(_), do: 0
end

# TEST MARKER
