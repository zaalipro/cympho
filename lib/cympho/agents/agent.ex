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
      values: [:idle, :running, :error, :sleeping, :offline],
      default: :idle

    field :config, :map, default: %{}
    field :instructions, :string
    field :instructions_path, :string
    field :max_concurrent_jobs, :integer, default: 3
    field :last_heartbeat_at, :utc_datetime

    field :adapter, Ecto.Enum,
      values: [:claude_code, :codex, :cursor, :http, :process]

    field :heartbeat_config, :map, default: %{}
    field :permissions, :map, default: %{}
    field :budget, :map, default: %{}

    field :governance_status, :string, default: "active"
    field :governance_reasoning, :string
    field :paused_at, :utc_datetime
    field :paused_by_user_id, :binary_id
    field :board_approval_id, :binary_id
    field :requires_board_approval, :boolean, default: false

    belongs_to :company, Cympho.Companies.Company
    belongs_to :parent, __MODULE__, foreign_key: :parent_id
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
      :instructions,
      :instructions_path,
      :max_concurrent_jobs,
      :last_heartbeat_at,
      :adapter,
      :heartbeat_config,
      :permissions,
      :budget,
      :company_id,
      :parent_id,
      :governance_status,
      :governance_reasoning,
      :paused_at,
      :paused_by_user_id,
      :board_approval_id,
      :requires_board_approval
    ])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, [:engineer, :product_manager, :designer, :ceo, :cto])
    |> validate_inclusion(:status, [:idle, :running, :error, :sleeping, :offline])
    |> unique_constraint(:url_key)
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
    |> foreign_key_constraint(:parent_id)
  end

  def status_options, do: [:idle, :running, :error, :sleeping, :offline]
  def role_options, do: [:engineer, :product_manager, :designer, :ceo, :cto]
  def adapter_options, do: [:claude_code, :codex, :cursor, :http, :process]

  def status_changeset(agent, attrs) do
    agent
    |> cast(attrs, [:status, :last_heartbeat_at])
    |> validate_inclusion(:status, [:idle, :running, :error, :sleeping, :offline])
  end
end
