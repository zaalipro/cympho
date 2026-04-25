defmodule Cympho.Finances.Biller do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @billing_cycles ~w(daily weekly monthly yearly)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "billers" do
    belongs_to :company, Company

    field :name, :string
    field :provider, :string

    field :billing_cycle, :string, default: "monthly"
    field :billing_day, :integer, default: 1

    field :config, :map, default: %{}
    field :is_active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(biller, attrs) do
    biller
    |> cast(attrs, [
      :company_id,
      :name,
      :provider,
      :billing_cycle,
      :billing_day,
      :config,
      :is_active
    ])
    |> validate_required([:company_id, :name, :provider])
    |> validate_inclusion(:billing_cycle, @billing_cycles)
    |> validate_number(:billing_day, greater_than: 0, less_than_or_equal_to: 31)
    |> unique_constraint([:company_id, :provider])
    |> foreign_key_constraint(:company_id)
  end

  def billing_cycles, do: @billing_cycles
end
