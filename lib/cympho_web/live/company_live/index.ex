defmodule CymphoWeb.CompanyLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Companies")
     |> assign(:companies, Companies.list_companies())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Companies")
    |> assign(:company, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Company")
    |> assign(:company, %Companies.Company{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    company = Companies.get_company!(id)

    socket
    |> assign(:page_title, "Edit Company")
    |> assign(:company, company)
  end

  @impl true
  def handle_event("delete_company", %{"id" => id}, socket) do
    company = Companies.get_company!(id)
    {:ok, _} = Companies.delete_company(company)

    {:noreply,
     socket
     |> assign(:companies, Companies.list_companies())
     |> put_flash(:info, "Company deleted successfully")}
  end

  def format_inserted_at(company) do
    Calendar.strftime(company.inserted_at, "%Y-%m-%d %H:%M")
  end
end
