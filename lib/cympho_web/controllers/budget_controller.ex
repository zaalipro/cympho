defmodule CymphoWeb.BudgetController do
  use CymphoWeb, :controller

  alias Cympho.Budgets

  action_fallback CymphoWeb.FallbackController

  def index(conn, _params) do
    budgets = Budgets.list_budgets()
    json(conn, %{data: budgets})
  end

  def show(conn, %{"id" => id}) do
    budget = Budgets.get_budget!(id)
    json(conn, %{data: budget})
  end

  def create(conn, %{"budget" => budget_params}) do
    case Budgets.create_budget(budget_params, conn.assigns[:current_user]) do
      {:ok, budget} ->
        conn
        |> put_status(:created)
        |> json(%{data: budget})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id, "budget" => budget_params}) do
    budget = Budgets.get_budget!(id)

    case Budgets.update_budget(budget, budget_params, conn.assigns[:current_user]) do
      {:ok, budget} ->
        json(conn, %{data: budget})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: translate_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    budget = Budgets.get_budget!(id)

    case Budgets.delete_budget(budget, conn.assigns[:current_user]) do
      {:ok, _} -> send_resp(conn, :no_content, "")
      {:error, changeset} -> json(conn, %{errors: translate_errors(changeset)})
    end
  end

  defp translate_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
