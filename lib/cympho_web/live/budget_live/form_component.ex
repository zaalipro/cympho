defmodule CymphoWeb.BudgetLive.FormComponent do
  use CymphoWeb, :live_component

  alias Cympho.Budgets

  @impl true
  def update(%{budget: budget} = assigns, socket) do
    changeset = Budgets.change_budget(budget)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:changeset, changeset)}
  end

  @impl true
  def handle_event("validate", %{"budget" => budget_params}, socket) do
    changeset =
      socket.assigns.budget
      |> Budgets.change_budget(budget_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :changeset, changeset)}
  end

  def handle_event("save", %{"budget" => budget_params}, socket) do
    save_budget(socket, socket.assigns.action, budget_params)
  end

  defp save_budget(socket, :edit, budget_params) do
    case Budgets.update_budget(socket.assigns.budget, budget_params) do
      {:ok, budget} ->
        {:noreply,
         socket
         |> put_flash(:info, "Budget updated successfully")
         |> push_navigate(to: ~p"/budgets/#{budget}")}

      {:pending_approval, _approval} ->
        {:noreply,
         socket
         |> put_flash(
           :warning,
           "Budget increase requires board approval. A proposal has been submitted."
         )
         |> push_navigate(to: ~p"/budgets")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end

  defp save_budget(socket, :new, budget_params) do
    case Budgets.create_budget(budget_params) do
      {:ok, budget} ->
        {:noreply,
         socket
         |> put_flash(:info, "Budget created successfully")
         |> push_navigate(to: ~p"/budgets/#{budget}")}

      {:pending_approval, _approval} ->
        {:noreply,
         socket
         |> put_flash(
           :warning,
           "Budget creation requires board approval due to the limit amount. A proposal has been submitted."
         )
         |> push_navigate(to: ~p"/budgets")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :changeset, changeset)}
    end
  end
end
