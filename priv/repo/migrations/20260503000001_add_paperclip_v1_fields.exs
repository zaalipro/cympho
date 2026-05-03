defmodule Cympho.Repo.Migrations.AddPaperclipV1Fields do
  use Ecto.Migration

  def change do
    alter table(:companies) do
      add :description, :text
      add :status, :string, null: false, default: "active"
      add :paused_at, :utc_datetime
      add :paused_reason, :text
      add :issue_prefix, :string, null: false, default: "CYM"
      add :issue_counter, :integer, null: false, default: 0
      add :budget_monthly_cents, :integer, null: false, default: 0
      add :spent_monthly_cents, :integer, null: false, default: 0
      add :attachment_max_bytes, :bigint, null: false, default: 25_000_000
      add :require_board_approval_for_new_agents, :boolean, null: false, default: false
      add :brand_color, :string, null: false, default: "#5e6ad2"
    end

    create index(:companies, [:status])

    alter table(:agents) do
      add :capabilities, :map, null: false, default: %{}
      add :icon, :string
      add :runtime_config, :map, null: false, default: %{}
      add :default_environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      add :context_mode, :string, null: false, default: "company"
      add :budget_monthly_cents, :integer, null: false, default: 0
      add :spent_monthly_cents, :integer, null: false, default: 0
      add :pause_reason, :text
      add :terminated_at, :utc_datetime
    end

    create index(:agents, [:default_environment_id])

    alter table(:issues) do
      add :assignee_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :checkout_run_id, references(:heartbeat_runs, type: :binary_id, on_delete: :nilify_all)
      add :checked_out_at, :utc_datetime
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :cancelled_at, :utc_datetime
      add :hidden_at, :utc_datetime
      add :issue_number, :integer
      add :origin_type, :string
      add :origin_id, :string
      add :request_depth, :integer, null: false, default: 0
      add :created_by_agent_id, references(:agents, type: :binary_id, on_delete: :nilify_all)
      add :created_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :project_workspace_id, references(:project_workspaces, type: :binary_id, on_delete: :nilify_all)
      add :execution_workspace_id, references(:execution_workspaces, type: :binary_id, on_delete: :nilify_all)
      add :monitor_state, :map, null: false, default: %{}
    end

    create index(:issues, [:assignee_user_id])
    create index(:issues, [:checkout_run_id])
    create index(:issues, [:created_by_agent_id])
    create index(:issues, [:created_by_user_id])
    create index(:issues, [:project_workspace_id])
    create index(:issues, [:execution_workspace_id])
    create unique_index(:issues, [:company_id, :issue_number],
             name: :issues_company_id_issue_number_index,
             where: "company_id IS NOT NULL AND issue_number IS NOT NULL"
           )

    alter table(:issue_activities) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
    end

    create index(:issue_activities, [:company_id, :inserted_at])

    alter table(:heartbeat_runs) do
      add :company_id, references(:companies, type: :binary_id, on_delete: :delete_all)
      add :invocation_source, :string, null: false, default: "heartbeat"
      add :external_run_id, :string
      add :log_excerpt, :text
    end

    create index(:heartbeat_runs, [:company_id])
    create index(:heartbeat_runs, [:company_id, :status])

    alter table(:agent_wakes) do
      add :status, :string, null: false, default: "pending"
      add :attempt_count, :integer, null: false, default: 0
      add :last_error, :text
      add :consumed_at, :utc_datetime
    end

    create index(:agent_wakes, [:status, :agent_id, :inserted_at])
  end
end
