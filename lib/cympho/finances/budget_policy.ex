defmodule Cympho.Finances.BudgetPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  alias Cympho.Companies.Company

  @scopes ~w(company agent project goal issue)
  @periods ~w(daily weekly monthly)
  @actions ~w(warn block)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "budget_policies" do
    belongs_to :company, Company

    field :scope, :string
    field :scope_id, :binary_id

    field :period, :string, default: "monthly"
    field :budget_limit_usd, :decimal
    field :warning_threshold_pct, :decimal, default: Decimal.new("80.0")

    field :action_on_exceed, :string, default: "warn"

    field :is_active, :boolean, default: true

    has_many :incidents, Cympho.Finances.BudgetIncident

    timestamps(type: :utc_datetime)
  end

  def changeset(budget_policy, attrs) do
    budget_policy
    |> cast(attrs, [
      :company_id,
      :scope,
      :scope_id,
      :period,
      :budget_limit_usd,
      :warning_threshold_pct,
      :action_on_exceed,
      :is_active
    ])
    |> validate_required([:company_id, :scope, :budget_limit_usd])
    |> validate_inclusion(:scope, @scopes)
    |> validate_inclusion(:period, @periods)
    |> validate_inclusion(:action_on_exceed, @actions)
    |> validate_number(:budget_limit_usd, greater_than: 0)
    |> validate_number(:warning_threshold_pct, greater_than: 0, less_than_or_equal_to: 100)
    |> foreign_key_constraint(:company_id)
    |> maybe_require_scope_id()
  end

  def scopes, do: @scopes
  def periods, do: @periods
  def actions, do: @actions

  defp maybe_require_scope_id(changeset) do
    case get_field(changeset, :scope) do
      "company" -> changeset
      nil -> changeset
      _ -> validate_required(changeset, [:scope_id])
    end
  end
end
