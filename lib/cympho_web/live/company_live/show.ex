defmodule CymphoWeb.CompanyLive.Show do
  use CymphoWeb, :live_view

  alias Cympho.Companies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    company = Companies.get_company!(id)
    memberships = Companies.list_memberships(company.id)

    {:ok,
     socket
     |> assign(:page_title, company.name)
     |> assign(:company, company)
     |> assign(:memberships, memberships)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :show, _params) do
    socket
    |> assign(:page_title, socket.assigns.company.name)
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)

  defp apply_action(socket, :edit, _params) do
    socket
    |> assign(:page_title, "Edit Company")
  end

  defp apply_action(socket, :manage_access, _params) do
    socket
    |> assign(:page_title, "Manage Access")
  end

  @impl true
  def handle_event("delete_membership", %{"id" => membership_id}, socket) do
    membership = Enum.find(socket.assigns.memberships, fn m -> m.id == membership_id end)

    if membership do
      {:ok, _} = Companies.delete_membership(membership)

      memberships = Companies.list_memberships(socket.assigns.company.id)

      {:noreply,
       socket
       |> assign(:memberships, memberships)
       |> put_flash(:info, "Membership removed successfully")}
    else
      {:noreply, put_flash(socket, :error, "Membership not found")}
    end
  end

  def format_inserted_at(company) do
    Calendar.strftime(company.inserted_at, "%Y-%m-%d %H:%M")
  end

  def role_label("admin"), do: "Admin"
  def role_label("member"), do: "Member"
  def role_label("viewer"), do: "Viewer"
  def role_label(_), do: "Unknown"
end
