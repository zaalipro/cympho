defmodule Cympho.Budgets.Budget do
  @moduledoc """
  Budget tracking with hard-stop enforcement for governance control.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Cympho.Companies.Company
  alias Cympho.Projects.Project
  alias Cympho.Agents.Agent

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "budgets" do
    field :name, :string
    field :scope_type, :string
    field :scope_id, :binary_id
    field :limit_amount, :decimal
    field :spent_amount, :decimal, default: 0
    field :currency, :string, default: "USD"
    field :period_start, :utc_datetime
    field :period_end, :utc_datetime
    field :hard_stop, :boolean, default: true
    field :status, :string, default: "active"
    field :threshold_alert_percentage, :integer, default: 80

    belongs_to :company, Company
    belongs_to :project, Project
    belongs_to :agent, Agent

    timestamps(type: :utc_datetime)
  end

  def changeset(budget, attrs) do
    budget
    |> cast(attrs, [
      :name,
      :scope_type,
      :scope_id,
      :limit_amount,
      :spent_amount,
      :currency,
      :period_start,
      :period_end,
      :hard_stop,
      :status,
      :threshold_alert_percentage,
      :company_id,
      :project_id,
      :agent_id
    ])
    |> validate_required([:name, :scope_type, :limit_amount])
    |> validate_number(:threshold_alert_percentage, greater_than: 0, less_than_or_equal_to: 100)
    |> validate_inclusion(:status, ["active", "exhausted", "cancelled"])
    |> validate_inclusion(:scope_type, ["company", "project", "agent", "custom"])
    |> validate_budget_period()
    |> validate_amounts()
  end

  def spend_changeset(budget, amount) do
    budget
    |> change()
    |> put_change(:spent_amount, Decimal.add(budget.spent_amount || Decimal.new(0), amount))
    |> maybe_mark_exhausted()
  end

  def available_amount(%__MODULE__{} = budget) do
    Decimal.sub(budget.limit_amount, budget.spent_amount || Decimal.new(0))
  end

  def utilization_percentage(%__MODULE__{} = budget) do
    if Decimal.eq?(budget.limit_amount, 0) do
      Decimal.new(0)
    else
      Decimal.mult(
        Decimal.div(budget.spent_amount || Decimal.new(0), budget.limit_amount),
        Decimal.new(100)
      )
    end
  end

  def exhausted?(%__MODULE__{} = budget) do
    available = available_amount(budget)
    Decimal.lt?(available, Decimal.new(0)) or Decimal.eq?(available, Decimal.new(0))
  end

  def at_threshold?(%__MODULE__{} = budget) do
    utilization = utilization_percentage(budget)
    threshold = Decimal.new(budget.threshold_alert_percentage)
    Decimal.gte?(utilization, threshold)
  end

  def active?(%__MODULE__{status: status}), do: status == "active"

  defp validate_budget_period(changeset) do
    period_start = get_change(changeset, :period_start)
    period_end = get_change(changeset, :period_end)

    if period_start && period_end do
      if DateTime.compare(period_start, period_end) == :gt do
        add_error(changeset, :period_end, "must be after period start")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp validate_amounts(changeset) do
    limit = get_change(changeset, :limit_amount)
    spent = get_change(changeset, :spent_amount)

    if limit && spent do
      if Decimal.lt?(limit, Decimal.new(0)) do
        add_error(changeset, :limit_amount, "must be positive")
      else
        changeset
      end
    else
      changeset
    end
  end

  defp maybe_mark_exhausted(changeset) do
    budget = apply_changes(changeset)

    if exhausted?(budget) and get_field(changeset, :hard_stop) == true do
      put_change(changeset, :status, "exhausted")
    else
      changeset
    end
  end
end
