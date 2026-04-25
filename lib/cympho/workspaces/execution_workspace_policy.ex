defmodule Cympho.Workspaces.ExecutionWorkspacePolicy do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "execution_workspace_policies" do
    field :name, :string
    field :max_concurrent_workspaces, :integer, default: 1
    field :max_idle_minutes, :integer, default: 60
    field :auto_cleanup, :boolean, default: true
    field :allowed_strategies, {:array, :string}, default: []
    field :default_strategy, :string
    field :require_approval, :boolean, default: false
    field :seed_on_create, :boolean, default: false
    field :default_seed_config, :map, default: %{}
    field :secret_injection_rules, :map, default: %{}
    field :metadata, :map, default: %{}

    belongs_to :company, Company
    belongs_to :project, Project

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :name,
      :max_concurrent_workspaces,
      :max_idle_minutes,
      :auto_cleanup,
      :allowed_strategies,
      :default_strategy,
      :require_approval,
      :seed_on_create,
      :default_seed_config,
      :secret_injection_rules,
      :metadata,
      :company_id,
      :project_id
    ])
    |> validate_required([:name, :company_id])
  end
end
