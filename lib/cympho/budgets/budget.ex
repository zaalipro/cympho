defmodule Cympho.Budgets.Budget do
  @moduledoc """
  Budget tracking with hard-stop enforcement for governance control.
  """
  use Ecto.Schema
  import Ecto.Changeset

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
    |> normalize_scope_fields()
    |> validate_scope_fields()
    |> validate_company_unchanged()
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

  defp normalize_scope_fields(changeset) do
    case get_field(changeset, :scope_type) do
      "company" ->
        changeset
        |> put_change(:scope_id, get_field(changeset, :company_id))
        |> put_change(:project_id, nil)
        |> put_change(:agent_id, nil)

      "project" ->
        normalize_relational_scope(changeset, :project_id, :agent_id)

      "agent" ->
        normalize_relational_scope(changeset, :agent_id, :project_id)

      "custom" ->
        changeset
        |> put_change(:project_id, nil)
        |> put_change(:agent_id, nil)

      _ ->
        changeset
    end
  end

  defp normalize_relational_scope(changeset, relation_field, other_relation_field) do
    scope_id_changed? = changed?(changeset, :scope_id)
    relation_id_changed? = changed?(changeset, relation_field)
    scope_id = get_field(changeset, :scope_id)
    relation_id = get_field(changeset, relation_field)

    if scope_id_changed? and relation_id_changed? and scope_id != relation_id do
      add_error(changeset, :scope_id, "must match #{relation_field}")
    else
      target_id =
        cond do
          scope_id_changed? -> scope_id
          relation_id_changed? -> relation_id
          true -> relation_id || scope_id
        end

      changeset
      |> put_change(:scope_id, target_id)
      |> put_change(relation_field, target_id)
      |> put_change(other_relation_field, nil)
    end
  end

  defp validate_scope_fields(changeset) do
    case get_field(changeset, :scope_type) do
      "company" -> validate_required(changeset, [:company_id, :scope_id])
      "project" -> validate_required(changeset, [:company_id, :scope_id, :project_id])
      "agent" -> validate_required(changeset, [:company_id, :scope_id, :agent_id])
      _ -> changeset
    end
  end

  defp validate_company_unchanged(%{data: %{id: id, company_id: company_id}} = changeset)
       when not is_nil(id) do
    case fetch_change(changeset, :company_id) do
      :error -> changeset
      {:ok, ^company_id} -> changeset
      {:ok, _other_company_id} -> add_error(changeset, :company_id, "cannot be changed")
    end
  end

  defp validate_company_unchanged(changeset), do: changeset

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
