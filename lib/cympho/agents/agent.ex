defmodule Cympho.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :name, :string
    field :url_key, :string
    field :title, :string
    field :role, Ecto.Enum, values: [:engineer, :product_manager, :designer, :ceo, :cto]

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

    field :adapter, Ecto.Enum, values: [:claude_code, :codex, :cursor, :http, :openclaw, :process]

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
      :adapter_failure_count
    ])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, [:engineer, :product_manager, :designer, :ceo, :cto])
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

  def role_options, do: [:engineer, :product_manager, :designer, :ceo, :cto]
  def adapter_options, do: [:claude_code, :codex, :cursor, :http, :openclaw, :process]
  def health_status_options, do: [:healthy, :degraded, :unavailable]

  def status_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:status, :last_heartbeat_at])
    |> validate_inclusion(:status, status_options())
  end
end
