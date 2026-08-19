defmodule CymphoWeb.BudgetLive.FormComponent do
  use CymphoWeb, :live_component

  alias Cympho.Budgets
  alias Cympho.CompanyRBAC
  alias Cympho.Companies
  alias Cympho.Finances

  @impl true
  def update(%{budget: budget} = assigns, socket) do
    changeset = Budgets.change_budget(budget)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"budget" => budget_params}, socket) do
    changeset =
      socket.assigns.budget
      |> Budgets.change_budget(budget_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"budget" => budget_params}, socket) do
    if current_board_authorized?(socket) do
      save_budget(socket, socket.assigns.action, budget_params)
    else
      {:noreply,
       socket
       |> put_flash(:error, "Your board authority changed. The budget was not saved.")
       |> push_navigate(to: ~p"/")}
    end
  end

  defp current_board_authorized?(socket) do
    user_id = socket.assigns[:current_user_id]
    company_id = socket.assigns[:current_company_id]
    budget_company_id = socket.assigns.budget.company_id

    is_binary(user_id) and is_binary(company_id) and company_id == budget_company_id and
      match?(
        %{role: role, is_board_member: true} when role in ~w(owner admin member),
        Companies.get_membership(user_id, company_id)
      ) and CompanyRBAC.manager?(user_id, company_id)
  end

  defp save_budget(socket, :edit, budget_params) do
    case Budgets.update_budget(socket.assigns.budget, budget_params) do
      {:ok, budget} ->
        _ = Finances.sync_budget_policy(budget)

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
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_budget(socket, :new, budget_params) do
    budget_params = budget_params_with_scope(socket, budget_params)

    case Budgets.create_budget(budget_params) do
      {:ok, budget} ->
        _ = Finances.sync_budget_policy(budget)

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
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end

  defp selected_scope_type(form, budget) do
    form
    |> field_value(:scope_type, budget.scope_type || "company")
    |> to_string()
  end

  defp hard_stop_enabled?(form, budget) do
    case field_value(form, :hard_stop, budget.hard_stop) do
      value when value in [true, "true", "on", 1, "1"] -> true
      value when value in [false, "false", "off", 0, "0"] -> false
      _ -> true
    end
  end

  defp scoped_scope_id_value(form, budget) do
    case field_value(form, :scope_id) do
      nil -> nil
      "" -> nil
      scope_id when scope_id == budget.company_id -> nil
      scope_id -> scope_id
    end
  end

  defp scope_id_label("project"), do: "Project ID"
  defp scope_id_label("agent"), do: "Agent ID"
  defp scope_id_label(_scope_type), do: "Scope ID"

  defp scope_id_placeholder("project"), do: "Paste a project UUID"
  defp scope_id_placeholder("agent"), do: "Paste an agent UUID"
  defp scope_id_placeholder(_scope_type), do: "Paste a scope UUID"

  defp budget_window_summary(form) do
    start_at = field_value(form, :period_start)
    end_at = field_value(form, :period_end)

    case {format_budget_window_date(start_at), format_budget_window_date(end_at)} do
      {nil, nil} -> "No fixed window"
      {start_text, nil} -> "Starts #{start_text}"
      {nil, end_text} -> "Runs until #{end_text}"
      {start_text, end_text} -> "#{start_text} to #{end_text}"
    end
  end

  defp budget_params_with_scope(socket, params) do
    budget = socket.assigns.budget
    company_id = Map.get(budget, :company_id)
    scope_type = params["scope_type"] || budget.scope_type

    params
    |> Map.put("company_id", company_id)
    |> put_if_blank("scope_id", default_scope_id(scope_type, budget))
    |> put_if_blank("status", budget.status || "active")
    |> put_if_blank("currency", budget.currency || "USD")
  end

  defp default_scope_id("company", %{company_id: company_id}), do: company_id
  defp default_scope_id("project", %{project_id: project_id}), do: project_id
  defp default_scope_id("agent", %{agent_id: agent_id}), do: agent_id
  defp default_scope_id(_scope_type, %{scope_id: scope_id}), do: scope_id
  defp default_scope_id(_scope_type, _budget), do: nil

  defp put_if_blank(params, _key, nil), do: params

  defp put_if_blank(params, key, value) do
    case Map.get(params, key) do
      nil -> Map.put(params, key, value)
      "" -> Map.put(params, key, value)
      _present -> params
    end
  end

  defp field_value(form, field, fallback \\ nil) do
    case Phoenix.HTML.Form.input_value(form, field) do
      nil -> fallback
      "" -> fallback
      value -> value
    end
  end

  defp format_budget_window_date(%DateTime{} = value) do
    value
    |> DateTime.to_date()
    |> Calendar.strftime("%b %-d, %Y")
  end

  defp format_budget_window_date(%NaiveDateTime{} = value) do
    value
    |> NaiveDateTime.to_date()
    |> Calendar.strftime("%b %-d, %Y")
  end

  defp format_budget_window_date(value) when is_binary(value) do
    cond do
      value == "" ->
        nil

      match?({:ok, _, _}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        format_budget_window_date(datetime)

      match?({:ok, _}, NaiveDateTime.from_iso8601(value <> ":00")) ->
        {:ok, datetime} = NaiveDateTime.from_iso8601(value <> ":00")
        format_budget_window_date(datetime)

      true ->
        value
    end
  end

  defp format_budget_window_date(_value), do: nil
end
