defmodule Cympho.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @leadership_roles [:ceo, :cto]
  @product_delivery_roles [:product_manager, :designer]
  @technical_delivery_roles [:engineer, :release_engineer, :qa_engineer]
  @business_delivery_roles [
    :researcher,
    :marketer,
    :content_strategist,
    :sales_development,
    :customer_support
  ]
  @delivery_roles @product_delivery_roles ++ @technical_delivery_roles ++ @business_delivery_roles
  @all_roles @leadership_roles ++ @delivery_roles
  @pr_delivery_roles [:engineer, :release_engineer, :qa_engineer]

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :name, :string
    field :url_key, :string
    field :title, :string

    field :role, Ecto.Enum, values: @all_roles

    field :status, Ecto.Enum,
      values: [
        :idle,
        :running,
        :error,
        :sleeping,
        :offline,
        :active,
        :paused,
        :pending_approval,
        :terminated
      ],
      default: :idle

    field :config, :map, default: %{}
    field :capabilities, :map, default: %{}
    field :icon, :string
    field :runtime_config, :map, default: %{}
    field :context_mode, :string, default: "company"
    field :budget_monthly_cents, :integer, default: 0
    field :spent_monthly_cents, :integer, default: 0
    field :instructions, :string
    field :instructions_path, :string
    field :max_concurrent_jobs, :integer, default: 3
    field :last_heartbeat_at, :utc_datetime

    field :adapter, Ecto.Enum,
      values: [
        :claude_code,
        :codex,
        :cursor,
        :http,
        :openai_chat,
        :openclaw,
        :process,
        :agrenting
      ]

    field :health_status, Ecto.Enum,
      values: [:healthy, :degraded, :unavailable],
      default: :healthy

    field :heartbeat_config, :map, default: %{}
    field :permissions, :map, default: %{}
    field :budget, :map, default: %{}

    field :governance_status, :string, default: "active"
    field :governance_reasoning, :string
    field :paused_at, :utc_datetime
    field :pause_reason, :string
    field :paused_by_user_id, :binary_id
    field :terminated_at, :utc_datetime
    field :board_approval_id, :binary_id
    field :requires_board_approval, :boolean, default: false
    field :adapter_failure_count, :integer, default: 0
    field :no_progress_failure_count, :integer, default: 0

    belongs_to :company, Cympho.Companies.Company
    belongs_to :project, Cympho.Projects.Project
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
    belongs_to :created_by_agent, __MODULE__, foreign_key: :created_by_agent_id

    belongs_to :default_environment, Cympho.Workspaces.Environment,
      foreign_key: :default_environment_id

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :api_keys, Cympho.Agents.AgentApiKey
    has_many :agent_skills, Cympho.Skills.AgentSkill

    timestamps(type: :utc_datetime)
  end

  def delivery_roles, do: @delivery_roles
  def business_delivery_roles, do: @business_delivery_roles
  def pr_delivery_roles, do: @pr_delivery_roles

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :url_key,
      :title,
      :role,
      :status,
      :config,
      :capabilities,
      :icon,
      :runtime_config,
      :context_mode,
      :budget_monthly_cents,
      :spent_monthly_cents,
      :instructions,
      :instructions_path,
      :max_concurrent_jobs,
      :last_heartbeat_at,
      :adapter,
      :health_status,
      :heartbeat_config,
      :permissions,
      :budget,
      :company_id,
      :project_id,
      :parent_id,
      :created_by_agent_id,
      :default_environment_id,
      :governance_status,
      :governance_reasoning,
      :paused_at,
      :pause_reason,
      :paused_by_user_id,
      :terminated_at,
      :board_approval_id,
      :requires_board_approval,
      :adapter_failure_count,
      :no_progress_failure_count
    ])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, @all_roles)
    |> validate_inclusion(:status, status_options())
    |> validate_inclusion(:health_status, [:healthy, :degraded, :unavailable])
    |> validate_inclusion(:context_mode, ["company", "project", "issue"])
    |> unique_constraint(:url_key)
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
    |> validate_number(:budget_monthly_cents, greater_than_or_equal_to: 0)
    |> validate_number(:spent_monthly_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:default_environment_id)
    |> prepare_changes(&validate_assignment_scope/1)
  end

  @doc """
  Restricted changeset for request-driven (user-facing) updates.

  Excludes authorization- and ledger-sensitive fields — `:company_id`,
  `:governance_status`, `:board_approval_id`, `:requires_board_approval`,
  `:spent_monthly_cents`, `:permissions`, `:capabilities` — so a user-supplied
  params map cannot mass-assign them. Those are managed only by the governance
  and billing flows (which write via `Ecto.Changeset.change/2`).
  """
  def update_changeset(agent, attrs) do
    agent
    |> cast(attrs, [
      :name,
      :url_key,
      :title,
      :role,
      :status,
      :config,
      :icon,
      :runtime_config,
      :context_mode,
      :budget_monthly_cents,
      :instructions,
      :instructions_path,
      :max_concurrent_jobs,
      :last_heartbeat_at,
      :adapter,
      :health_status,
      :heartbeat_config,
      :budget,
      :project_id,
      :parent_id,
      :created_by_agent_id,
      :default_environment_id,
      :governance_reasoning,
      :paused_at,
      :pause_reason,
      :paused_by_user_id,
      :terminated_at,
      :adapter_failure_count,
      :no_progress_failure_count
    ])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, @all_roles)
    |> validate_inclusion(:status, status_options())
    |> validate_inclusion(:health_status, [:healthy, :degraded, :unavailable])
    |> validate_inclusion(:context_mode, ["company", "project", "issue"])
    |> unique_constraint(:url_key)
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
    |> validate_number(:budget_monthly_cents, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:created_by_agent_id)
    |> foreign_key_constraint(:default_environment_id)
    |> prepare_changes(&validate_assignment_scope/1)
  end

  defp validate_assignment_scope(changeset) do
    company_id = get_field(changeset, :company_id)

    changeset
    |> validate_parent_assignment()
    |> validate_same_company(:project_id, Cympho.Projects.Project, company_id)
    |> validate_same_company(:created_by_agent_id, __MODULE__, company_id)
    |> validate_default_environment(company_id)
  end

  defp validate_same_company(changeset, field, schema, company_id) do
    case get_field(changeset, field) do
      nil ->
        changeset

      id ->
        case changeset.repo.get(schema, id) do
          %{company_id: ^company_id} -> changeset
          nil -> changeset
          _record -> add_error(changeset, field, "must belong to the same company")
        end
    end
  end

  defp validate_default_environment(changeset, company_id) do
    environment_id = get_field(changeset, :default_environment_id)
    project_id = get_field(changeset, :project_id)

    case environment_id && changeset.repo.get(Cympho.Workspaces.Environment, environment_id) do
      nil ->
        changeset

      %{company_id: ^company_id, project_id: environment_project_id}
      when is_nil(project_id) or is_nil(environment_project_id) or
             environment_project_id == project_id ->
        changeset

      %{company_id: ^company_id} ->
        add_error(changeset, :default_environment_id, "must belong to the agent project")

      _environment ->
        add_error(changeset, :default_environment_id, "must belong to the same company")
    end
  end

  defp validate_parent_assignment(changeset) do
    if parent_scope_changed?(changeset) do
      case get_field(changeset, :parent_id) do
        nil ->
          changeset

        parent_id ->
          validate_parent(changeset, changeset.repo.get(__MODULE__, parent_id))
      end
    else
      changeset
    end
  end

  defp parent_scope_changed?(changeset) do
    match?({:ok, _value}, fetch_change(changeset, :parent_id)) or
      match?({:ok, _value}, fetch_change(changeset, :company_id))
  end

  defp validate_parent(changeset, nil), do: changeset

  defp validate_parent(changeset, %__MODULE__{} = parent) do
    cond do
      parent.company_id != get_field(changeset, :company_id) ->
        add_error(changeset, :parent_id, "must belong to the same company")

      hierarchy_cycle?(changeset.repo, parent.id, changeset.data.id, MapSet.new()) ->
        add_error(changeset, :parent_id, "would create a hierarchy cycle")

      true ->
        changeset
    end
  end

  defp hierarchy_cycle?(_repo, _parent_id, nil, _visited), do: false
  defp hierarchy_cycle?(_repo, agent_id, agent_id, _visited), do: true

  defp hierarchy_cycle?(repo, parent_id, agent_id, visited) do
    if MapSet.member?(visited, parent_id) do
      true
    else
      case repo.get(__MODULE__, parent_id) do
        nil ->
          false

        %__MODULE__{parent_id: nil} ->
          false

        %__MODULE__{parent_id: next_parent_id} ->
          hierarchy_cycle?(repo, next_parent_id, agent_id, MapSet.put(visited, parent_id))
      end
    end
  end

  def status_options,
    do: [
      :idle,
      :running,
      :error,
      :sleeping,
      :offline,
      :active,
      :paused,
      :pending_approval,
      :terminated
    ]

  def role_options, do: @all_roles

  def role_strings, do: Enum.map(@all_roles, &Atom.to_string/1)

  def normalize_role(role) when is_atom(role) and role in @all_roles, do: role

  def normalize_role(role) when is_binary(role) do
    normalized =
      role
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    alias_role =
      case normalized do
        "product" -> "product_manager"
        "pm" -> "product_manager"
        "design" -> "designer"
        "qa" -> "qa_engineer"
        "quality_assurance" -> "qa_engineer"
        "marketing" -> "marketer"
        "growth" -> "marketer"
        "content" -> "content_strategist"
        "social" -> "content_strategist"
        "sales" -> "sales_development"
        "outreach" -> "sales_development"
        "support" -> "customer_support"
        "research" -> "researcher"
        other -> other
      end

    if alias_role in role_strings() do
      String.to_existing_atom(alias_role)
    end
  end

  def normalize_role(_), do: nil

  def role_label(:ceo), do: "CEO"
  def role_label(:cto), do: "CTO"
  def role_label(:qa_engineer), do: "QA Engineer"
  def role_label(:product_manager), do: "Product Manager"
  def role_label(:content_strategist), do: "Content Strategist"
  def role_label(:sales_development), do: "Sales Development"
  def role_label(:customer_support), do: "Customer Support"

  def role_label(role) do
    role
    |> to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def role_title(:ceo), do: "Chief Executive Officer"
  def role_title(:cto), do: "Chief Technology Officer"
  def role_title(:engineer), do: "Software Engineer"
  def role_title(role), do: role_label(role)

  def adapter_options,
    do: [:claude_code, :codex, :cursor, :http, :openai_chat, :openclaw, :process, :agrenting]

  def health_status_options, do: [:healthy, :degraded, :unavailable]

  def status_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:status, :last_heartbeat_at])
    |> validate_inclusion(:status, status_options())
  end
end
