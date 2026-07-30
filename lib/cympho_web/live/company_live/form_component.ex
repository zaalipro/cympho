defmodule CymphoWeb.CompanyLive.FormComponent do
  use CymphoWeb, :live_component

  alias Cympho.Companies

  @impl true
  def update(%{company: company} = assigns, socket) do
    changeset = Companies.change_company(company)

    {:ok,
     socket
     |> assign(assigns)
     |> assign_form(changeset)}
  end

  @impl true
  def handle_event("validate", %{"company" => company_params}, socket) do
    changeset =
      socket.assigns.company
      |> Companies.change_company(company_params)
      |> Map.put(:action, :validate)

    {:noreply, assign_form(socket, changeset)}
  end

  def handle_event("save", %{"company" => company_params}, socket) do
    save_company(socket, socket.assigns.action, company_params)
  end

  defp save_company(socket, :edit, company_params) do
    case Companies.update_company(socket.assigns.company, company_params) do
      {:ok, company} ->
        {:noreply,
         socket
         |> put_flash(:info, "Company updated successfully")
         |> push_navigate(to: ~p"/companies/#{company}")}

      {:pending_approval, _approval} ->
        {:noreply,
         socket
         |> put_flash(
           :warning,
           "Governance config change requires board approval. A proposal has been submitted."
         )
         |> push_navigate(to: ~p"/companies")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}
    end
  end

  defp save_company(socket, :new, company_params) do
    case Companies.create_company_for_owner(company_params, socket.assigns.current_user.id) do
      {:ok, company} ->
        {:noreply,
         socket
         |> put_flash(:info, "Company created. You are now its owner.")
         |> redirect(to: ~p"/switch-company/#{company.id}?return_to=/companies/#{company.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign_form(socket, changeset)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "We couldn't create the company. Try again.")}
    end
  end

  defp assign_form(socket, %Ecto.Changeset{} = changeset) do
    assign(socket, :form, to_form(changeset))
  end
end
