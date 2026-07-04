defmodule Cympho.Repo.Migrations.CreateLaunchItems do
  use Ecto.Migration

  def change do
    create table(:launch_items, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:title, :string, null: false)
      add(:status, :string, null: false, default: "planned")
      add(:is_blocked, :boolean, null: false, default: false)

      add(:company_id, references(:companies, type: :binary_id, on_delete: :delete_all),
        null: false
      )

      add(:owner_user_id, references(:users, type: :binary_id), null: false)

      timestamps(type: :utc_datetime)
    end

    create(index(:launch_items, [:company_id]))
    create(index(:launch_items, [:owner_user_id]))
    create(index(:launch_items, [:status]))
    create(index(:launch_items, [:is_blocked]))
    create(index(:launch_items, [:inserted_at]))
  end
end