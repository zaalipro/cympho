defmodule Cympho.Repo.Migrations.CreateMcpToolRegistryAndGrants do
  use Ecto.Migration

  def change do
    create table(:mcp_registered_tools, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :name, :string, null: false
      add :description, :text
      add :input_schema, :map, null: false, default: %{}
      add :plugin_id, :binary_id
      add :status, :string, null: false, default: "active"
      add :metadata, :map, null: false, default: %{}

      # usec so successive grant/register writes order stably within a second
      timestamps(type: :utc_datetime_usec)
    end

    create index(:mcp_registered_tools, [:company_id])
    create index(:mcp_registered_tools, [:company_id, :status])
    create unique_index(:mcp_registered_tools, [:company_id, :name],
             where: "status = 'active'",
             name: :mcp_registered_tools_company_name_active_idx
           )

    create table(:mcp_tool_grants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false

      add :tool_id, references(:mcp_registered_tools, type: :binary_id, on_delete: :delete_all)
      add :tool_name, :string, null: false
      # nil agent_id => company-wide grant
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all)
      # allow | deny | pending | revoked
      add :status, :string, null: false, default: "pending"
      add :reason, :text
      add :granted_by_type, :string
      add :granted_by_id, :string
      add :metadata, :map, null: false, default: %{}
      # Monotonic sequence within company for stable latest-grant resolution.
      add :sequence, :bigserial

      timestamps(type: :utc_datetime_usec)
    end
    create index(:mcp_tool_grants, [:company_id])
    create index(:mcp_tool_grants, [:company_id, :tool_name])
    create index(:mcp_tool_grants, [:company_id, :agent_id, :tool_name])
    create index(:mcp_tool_grants, [:status])
  end
end
