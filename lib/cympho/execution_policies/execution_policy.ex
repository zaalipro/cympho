defmodule Cympho.ExecutionPolicies.ExecutionPolicy do
  @moduledoc """
  Defines an execution policy with sequential stages for issue lifecycle management.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "execution_policies" do
    field :name, :string
    field :stage_configs, {:array, :map}, default: []

    belongs_to :company, Cympho.Companies.Company

    timestamps()
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [:name, :stage_configs, :company_id])
    |> validate_required([:name, :stage_configs, :company_id])
    |> assoc_constraint(:company)
  end
end
