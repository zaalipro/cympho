defmodule CymphoWeb.CompanyLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Companies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    company = Companies.get_company!(id)
    memberships = Companies.list_memberships(company.id)
    {:ok, socket |> assign(:page_title, company.name) |> assign(:company, company) |> assign(:memberships, memberships) |> assign(:show_pause_modal, false) |> assign(:show_resume_modal, false) |> assign(:pause_reason, "")}
  end

  @impl true
  def handle_params(params, _url, socket), do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  defp apply_action(socket, :show, _params), do: socket |> assign(:page_title, socket.assigns.company.name)
  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)
  defp apply_action(socket, :edit, _params), do: socket |> assign(:page_title, "Edit Company")
  defp apply_action(socket, :manage_access, _params), do: socket |> assign(:page_title, "Manage Access")

  @impl true
  def handle_event("delete_membership", %{"id" => membership_id}, socket) do
    membership = Enum.find(socket.assigns.memberships, fn m -> m.id == membership_id end)
    if membership do
      {:ok, _} = Companies.delete_membership(membership)
      {:noreply, socket |> assign(:memberships, Companies.list_memberships(socket.assigns.company.id)) |> put_flash(:info, "Membership removed")}
    else
      {:noreply, put_flash(socket, :error, "Membership not found")}
    end
  end

  def handle_event("show_pause_modal", _, socket), do: {:noreply, assign(socket, show_pause_modal: true, pause_reason: "")}
  def handle_event("hide_pause_modal", _, socket), do: {:noreply, assign(socket, show_pause_modal: false)}
  def handle_event("update_pause_reason", %{"pause_reason" => r}, socket), do: {:noreply, assign(socket, pause_reason: r)}
  def handle_event("pause_company", _, socket) do
    reason = if socket.assigns.pause_reason == "", do: "Manual pause", else: socket.assigns.pause_reason
    case Companies.pause_company(socket.assigns.company, reason) do
      {:ok, u} -> {:noreply, socket |> assign(:company, u) |> assign(:show_pause_modal, false) |> put_flash(:info, "Company paused.")}
      {:error, _} -> {:noreply, socket |> assign(:show_pause_modal, false) |> put_flash(:error, "Failed to pause.")}
    end
  end
  def handle_event("show_resume_modal", _, socket), do: {:noreply, assign(socket, show_resume_modal: true)}
  def handle_event("hide_resume_modal", _, socket), do: {:noreply, assign(socket, show_resume_modal: false)}
  def handle_event("resume_company", _, socket) do
    case Companies.resume_company(socket.assigns.company) do
      {:ok, u} -> {:noreply, socket |> assign(:company, u) |> assign(:show_resume_modal, false) |> put_flash(:info, "Company resumed.")}
      {:error, _} -> {:noreply, socket |> assign(:show_resume_modal, false) |> put_flash(:error, "Failed to resume.")}
    end
  end

  def format_inserted_at(company), do: Calendar.strftime(company.inserted_at, "%Y-%m-%d %H:%M")
  def role_label("owner"), do: "Owner"
  def role_label("admin"), do: "Admin"
  def role_label("member"), do: "Member"
  def role_label("viewer"), do: "Viewer"
  def role_label(_), do: "Unknown"
end
