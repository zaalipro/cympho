defmodule CymphoWeb.LaunchItemLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.Companies
  alias Cympho.LaunchItems
  alias Cympho.LaunchItems.LaunchItem

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign_tracker(socket)}
  end

  @impl true
  def handle_params(_params, _url, socket), do: {:noreply, socket}

  @impl true
  def handle_event("create_launch_item", %{"launch_item" => params}, socket) do
    case current_company(socket) do
      nil ->
        {:noreply, put_flash(socket, :error, "Choose a company before creating launch items.")}

      %{id: company_id} ->
        attrs =
          params
          |> Map.put("company_id", company_id)
          |> maybe_default_owner(socket)

        case LaunchItems.create_launch_item(attrs) do
          {:ok, _item} ->
            {:noreply,
             socket
             |> put_flash(:info, "Launch item created")
             |> assign_tracker()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> put_flash(:error, "Could not create launch item")
             |> assign(:form, to_form(Map.put(changeset, :action, :insert), as: :launch_item))}
        end
    end
  end

  def handle_event("update_owner", %{"_id" => id, "owner_user_id" => owner_user_id}, socket) do
    update_launch_item(socket, id, %{owner_user_id: owner_user_id}, "Owner updated")
  end

  def handle_event("update_status", %{"id" => id, "status" => status}, socket) do
    update_launch_item(socket, id, %{status: status}, "Status updated")
  end

  def handle_event("toggle_blocked", %{"id" => id}, socket) do
    case scoped_launch_item(socket, id) do
      {:ok, item} ->
        update_launch_item(socket, item, %{is_blocked: not item.is_blocked}, blocked_flash(item))

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Launch item not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame page="launch" title="Launch checklist" data-ui-complex-page>
      <.flash_line flash={@flash} />

      <%!-- Problems first. With no items at all the list carries the only empty state. --%>
      <.band_card
        :if={@summary.total > 0}
        id="launch-blocked-t"
        title="Blocked"
        section_id="blocked-work-view"
      >
        <:header_end>
          <span class="meta mono">{@summary.blocked_count}</span>
        </:header_end>
        <ul :if={blocked_items(@launch_items) != []} class="rows">
          <.list_row
            :for={item <- blocked_items(@launch_items)}
            id={"blocked-launch-item-#{item.id}"}
            title={item.title}
            icon="i-stop"
            kind={:problem}
          >
            <:meta>
              {status_label(item.status)}<span aria-hidden="true"> · </span>{owner_name(
                item.owner_user
              )}
            </:meta>
          </.list_row>
        </ul>
        <p :if={blocked_items(@launch_items) == []} class="gl-sub pn-line">
          No blocked launch items.
        </p>
      </.band_card>

      <.form_pair
        id="launch-item-create-form"
        for={@form}
        phx-submit="create_launch_item"
        heading="After you add it"
        verb="add"
      >
        <.band_card id="li-new-t" title="New item">
          <div class="flds">
            <.input
              field={@form[:title]}
              label="Title"
              required
              placeholder="QA sign-off, release notes…"
              wrapper_class="full"
            />
            <.input
              field={@form[:owner_user_id]}
              type="select"
              label="Owner"
              required
              options={owner_options(@company_members)}
            />
            <.input
              field={@form[:status]}
              type="select"
              label="Status"
              required
              options={status_options()}
            />
            <.input field={@form[:is_blocked]} type="checkbox" label="Blocked" wrapper_class="full" />
          </div>
        </.band_card>
        <:effect>
          <.consequences rows={[{:done, "It joins the checklist with its owner and status."}]} />
        </:effect>
        <:primary>
          <.primary_pill type="submit" phx-disable-with="Adding…">Add to checklist</.primary_pill>
        </:primary>
      </.form_pair>

      <.band_card id="launch-list-t" title="Everything on the checklist">
        <:header_end>
          <span :if={@summary.total > 0} class="meta">
            {@summary.completed_count} of {@summary.total} done
          </span>
        </:header_end>
        <.quiet_empty :if={@launch_items == []} title="No launch items yet">
          Add the first one above to start tracking what is left before launch.
        </.quiet_empty>
        <ul :if={@launch_items != []} class="rows">
          <.list_row
            :for={item <- @launch_items}
            id={"launch-item-#{item.id}"}
            title={item.title}
            status={item.is_blocked && {:stopped, "Blocked"}}
          >
            <:below>
              <div class="li-ctl">
                <form id={"launch-item-owner-#{item.id}"} phx-change="update_owner" class="li-own">
                  <input type="hidden" name="_id" value={item.id} />
                  <span class="li-sel">
                    <select
                      name="owner_user_id"
                      class="fld-sel"
                      aria-label={"Owner of #{item.title}"}
                    >
                      <option
                        :for={{label, value} <- owner_options(@company_members)}
                        value={value}
                        selected={value == item.owner_user_id}
                      >
                        {label}
                      </option>
                    </select>
                    <.r3_icon name="i-chev-down" class="ico s16" />
                  </span>
                </form>
                <div class="seg" role="group" aria-label={"Status of #{item.title}"}>
                  <button
                    :for={{status, label} <- status_buttons()}
                    type="button"
                    phx-click="update_status"
                    phx-value-id={item.id}
                    phx-value-status={status}
                    aria-pressed={to_string(item.status == status)}
                  >
                    {label}
                  </button>
                </div>
                <.pill phx-click="toggle_blocked" phx-value-id={item.id}>
                  {blocked_toggle_label(item.is_blocked)}
                </.pill>
              </div>
            </:below>
          </.list_row>
        </ul>
      </.band_card>
    </.page_frame>
    """
  end

  defp assign_tracker(socket) do
    company = current_company(socket)
    members = company_members(company)
    launch_items = company_launch_items(company)
    summary = company_launch_summary(company)

    socket
    |> assign(:page_title, "Launch checklist")
    |> assign(:launch_items, launch_items)
    |> assign(:company_members, members)
    |> assign(:summary, summary)
    |> assign(:form, create_form(socket, company))
  end

  defp create_form(socket, company) do
    attrs = default_launch_item_attrs(socket, company)

    %LaunchItem{}
    |> LaunchItems.change_launch_item(attrs)
    |> to_form(as: :launch_item)
  end

  defp default_launch_item_attrs(socket, %{id: company_id}) do
    current_user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    %{
      company_id: company_id,
      owner_user_id: current_user_id,
      status: "planned",
      is_blocked: false
    }
  end

  defp default_launch_item_attrs(_socket, _company), do: %{}

  defp company_launch_items(%{id: company_id}),
    do: LaunchItems.list_company_launch_items(company_id)

  defp company_launch_items(_), do: []

  defp company_launch_summary(%{id: company_id}), do: LaunchItems.company_readiness(company_id)
  defp company_launch_summary(_), do: LaunchItems.empty_company_readiness()

  defp company_members(%{id: company_id}) do
    Companies.list_memberships(company_id)
  end

  defp company_members(_), do: []

  defp current_company(socket), do: socket.assigns[:current_company]

  defp scoped_launch_item(socket, id) do
    case current_company(socket) do
      %{id: company_id} -> LaunchItems.get_company_launch_item(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp update_launch_item(socket, id_or_item, attrs, flash_message) do
    with {:ok, item} <- normalize_item(socket, id_or_item),
         {:ok, _updated} <- LaunchItems.update_launch_item(item, attrs) do
      {:noreply,
       socket
       |> put_flash(:info, flash_message)
       |> assign_tracker()}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Launch item not found")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, launch_item_error_message(changeset))}
    end
  end

  defp normalize_item(_socket, %LaunchItem{} = item), do: {:ok, item}
  defp normalize_item(socket, id), do: scoped_launch_item(socket, id)

  defp maybe_default_owner(params, %{assigns: %{current_user: %{id: user_id}}}) do
    Map.put_new(params, "owner_user_id", user_id)
  end

  defp maybe_default_owner(params, _socket), do: params

  defp launch_item_error_message(changeset) do
    changeset.errors
    |> Enum.map(fn {field, {msg, _}} -> "#{humanize(field)} #{msg}" end)
    |> case do
      [] -> "Could not update launch item"
      [single] -> single
      messages -> Enum.join(messages, ", ")
    end
  end

  defp blocked_flash(%LaunchItem{is_blocked: true}), do: "Launch item unblocked"
  defp blocked_flash(%LaunchItem{}), do: "Launch item blocked"

  defp humanize(field) when is_atom(field) do
    field
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def status_options do
    LaunchItem.status_options()
    |> Enum.map(fn status -> {status_label(status), status} end)
  end

  def status_label("planned"), do: "Planned"
  def status_label("in_progress"), do: "In progress"
  def status_label("completed"), do: "Completed"

  # A member reads as their name; the email is added only when two members share
  # a name (or replaces a blank one), so the owner select fits a phone row.
  def owner_options(company_members) do
    users = Enum.map(company_members, & &1.user)
    shared = users |> Enum.frequencies_by(&owner_name/1) |> Map.filter(fn {_, n} -> n > 1 end)

    Enum.map(users, fn user ->
      label =
        if Map.has_key?(shared, owner_name(user)), do: member_label(user), else: owner_name(user)

      {label, user.id}
    end)
  end

  def owner_name(%{name: name}) when is_binary(name) and name != "", do: name
  def owner_name(%{email: email}), do: email
  def owner_name(_user), do: "Unassigned"

  def blocked_items(items), do: Enum.filter(items, & &1.is_blocked)

  def member_label(%{name: name, email: email}) when is_binary(name) and name != "" do
    "#{name} · #{email}"
  end

  def member_label(%{email: email}), do: email

  # The three status buttons, in the order work moves through them.
  def status_buttons do
    [{"planned", "Planned"}, {"in_progress", "In progress"}, {"completed", "Completed"}]
  end

  def blocked_toggle_label(true), do: "Unblock"
  def blocked_toggle_label(false), do: "Mark blocked"
end
