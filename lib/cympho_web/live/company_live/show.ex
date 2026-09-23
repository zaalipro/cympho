defmodule CymphoWeb.CompanyLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Companies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    if Companies.has_access?(user.id, id) do
      company = Companies.get_company!(id)
      memberships = Companies.list_memberships(company.id)

      {:ok,
       socket
       |> assign(:page_title, company.name)
       |> assign(:company, company)
       |> assign(:memberships, memberships)
       |> assign(:can_manage?, company_manager?(user.id, company.id))
       |> assign(:show_pause_modal, false)
       |> assign(:show_resume_modal, false)
       |> assign(:pause_reason, "")}
    else
      {:ok,
       socket
       |> put_flash(:error, "Company not found or you do not have access.")
       |> redirect(to: ~p"/companies")}
    end
  end

  @impl true
  def handle_params(params, _url, socket),
    do: {:noreply, apply_action(socket, socket.assigns.live_action, params)}

  defp apply_action(socket, :show, _params),
    do: socket |> assign(:page_title, socket.assigns.company.name)

  defp apply_action(socket, nil, params), do: apply_action(socket, :show, params)
  defp apply_action(socket, :edit, _params), do: socket |> assign(:page_title, "Edit Company")

  defp apply_action(socket, :manage_access, _params),
    do: socket |> assign(:page_title, "Manage Access")

  @impl true
  def handle_event("delete_membership", %{"id" => membership_id}, socket) do
    authorize_company_management(socket, "Membership not found", fn socket ->
      memberships = Companies.list_memberships(socket.assigns.company.id)
      membership = Enum.find(memberships, fn membership -> membership.id == membership_id end)

      case membership &&
             Companies.delete_membership_for_actor(
               socket.assigns.current_user.id,
               socket.assigns.company.id,
               membership.id
             ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:memberships, Companies.list_memberships(socket.assigns.company.id))
           |> put_flash(:info, "Membership removed")}

        {:error, :last_owner} ->
          {:noreply, put_flash(socket, :error, "Cannot remove the last owner")}

        _ ->
          {:noreply, put_flash(socket, :error, "Membership not found")}
      end
    end)
  end

  def handle_event("show_pause_modal", _, socket),
    do: maybe_show_runtime_modal(socket, :pause)

  def handle_event("hide_pause_modal", _, socket),
    do: {:noreply, assign(socket, show_pause_modal: false)}

  def handle_event("update_pause_reason", %{"pause_reason" => r}, socket),
    do: {:noreply, assign(socket, pause_reason: r)}

  def handle_event("pause_company", _, socket) do
    reason =
      if socket.assigns.pause_reason == "", do: "Manual pause", else: socket.assigns.pause_reason

    authorize_company_management(socket, fn socket ->
      case Companies.pause_company(socket.assigns.company, reason) do
        {:ok, u} ->
          {:noreply,
           socket
           |> assign(:company, u)
           |> assign(:show_pause_modal, false)
           |> put_flash(:info, "Company paused.")}

        {:error, _} ->
          {:noreply,
           socket |> assign(:show_pause_modal, false) |> put_flash(:error, "Failed to pause.")}
      end
    end)
  end

  def handle_event("show_resume_modal", _, socket),
    do: maybe_show_runtime_modal(socket, :resume)

  def handle_event("hide_resume_modal", _, socket),
    do: {:noreply, assign(socket, show_resume_modal: false)}

  def handle_event("resume_company", _, socket) do
    authorize_company_management(socket, fn socket ->
      case Companies.resume_company(socket.assigns.company) do
        {:ok, u} ->
          {:noreply,
           socket
           |> assign(:company, u)
           |> assign(:show_resume_modal, false)
           |> put_flash(:info, "Company resumed.")}

        {:error, _} ->
          {:noreply,
           socket |> assign(:show_resume_modal, false) |> put_flash(:error, "Failed to resume.")}
      end
    end)
  end

  defp maybe_show_runtime_modal(socket, :pause) do
    authorize_company_management(socket, fn socket ->
      {:noreply, assign(socket, show_pause_modal: true, pause_reason: "")}
    end)
  end

  defp maybe_show_runtime_modal(socket, :resume) do
    authorize_company_management(socket, fn socket ->
      {:noreply, assign(socket, show_resume_modal: true)}
    end)
  end

  defp maybe_show_runtime_modal(socket, _mode) do
    {:noreply, put_flash(socket, :error, "You cannot control this company's runtime.")}
  end

  defp authorize_company_management(socket, action) when is_function(action, 1) do
    authorize_company_management(socket, nil, action)
  end

  defp authorize_company_management(socket, denied_message, action)
       when is_function(action, 1) do
    user_id = socket.assigns.current_user.id
    company_id = socket.assigns.company.id

    if company_manager?(user_id, company_id) do
      action.(assign(socket, :can_manage?, true))
    else
      denied_message = denied_message || "You cannot control this company's runtime."

      {:noreply,
       socket
       |> assign(:can_manage?, false)
       |> assign(:show_pause_modal, false)
       |> assign(:show_resume_modal, false)
       |> put_flash(:error, denied_message)}
    end
  end

  defp company_manager?(user_id, company_id)
       when is_binary(user_id) and is_binary(company_id) do
    Cympho.CompanyRBAC.manager?(user_id, company_id)
  end

  defp company_manager?(_user_id, _company_id), do: false

  def format_inserted_at(company), do: Calendar.strftime(company.inserted_at, "%Y-%m-%d %H:%M")
  def role_label("owner"), do: "Owner"
  def role_label("admin"), do: "Admin"
  def role_label("member"), do: "Member"
  def role_label("viewer"), do: "Viewer"
  def role_label(_), do: "Unknown"
end
