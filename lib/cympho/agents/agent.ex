defmodule Cympho.Agents.Agent do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "agents" do
    field :name, :string
    field :url_key, :string
    field :role, Ecto.Enum, values: [:engineer, :product_manager, :designer, :ceo, :cto]
    field :status, Ecto.Enum, values: [:idle, :running, :error], default: :idle
    field :config, :map, default: %{}
    field :instructions, :string
    field :max_concurrent_jobs, :integer, default: 3

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(agent, attrs) do
    agent
    |> cast(attrs, [:name, :url_key, :role, :status, :config, :instructions, :max_concurrent_jobs])
    |> validate_required([:name, :role])
    |> validate_inclusion(:role, [:engineer, :product_manager, :designer, :ceo, :cto])
    |> validate_inclusion(:status, [:idle, :running, :error])
    |> unique_constraint(:url_key)
    |> validate_number(:max_concurrent_jobs, greater_than: 0)
  end

  def status_options, do: [:idle, :running, :error]
  def role_options, do: [:engineer, :product_manager, :designer, :ceo, :cto]
end