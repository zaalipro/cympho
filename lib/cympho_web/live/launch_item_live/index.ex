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
    <.page size="wide" data-ui-complex-page class="ember-aurora">
      <div class="relative z-[1]">
        <.header>
          <span class="ember-eyebrow">Launch readiness</span>
          <h1 class="ember-ink mt-4 font-serif text-[clamp(28px,4vw,42px)] font-510 leading-[1.08] tracking-[-0.02em]">
            Launch Tracker
          </h1>
          <p class="mt-2 max-w-2xl text-[15px] leading-6 text-text-tertiary">
            What is left before launch, and who owns each piece.
          </p>
          <:actions>
            <.app_link
              navigate={~p"/dashboard"}
              class="rounded-lg border border-border bg-panel px-3 py-2 text-sm font-510 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
            >
              Back to dashboard
            </.app_link>
          </:actions>
        </.header>

        <div class="grid gap-5 xl:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]">
          <section class="space-y-5">
            <%!-- An empty tracker had a 0% ring, four zeroed tiles, and three
                 different "nothing here yet" messages. With no items the list
                 below carries the only empty state. --%>
            <div
              :if={@summary.total > 0}
              class={[
                "relative rounded-2xl border p-5 shadow-[inset_0_1px_0_0_rgba(255,250,245,0.08),0_1px_2px_rgb(var(--shadow-rgb)/0.3),0_24px_64px_rgb(var(--shadow-rgb)/0.28)]",
                summary_tone_class(@summary.tone)
              ]}
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <p class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-current/80">
                    Readiness summary
                  </p>
                  <%!-- @summary.detail spells out the same four counts the tiles
                       below already show ("2 open, 2 blocked, 1 completed…"). --%>
                  <h2 class="mt-2 text-2xl font-590 text-current" title={@summary.detail}>
                    {@summary.headline}<span class="sr-only"> — {@summary.detail}</span>
                  </h2>
                </div>

                <div class="rounded-2xl border border-current/15 bg-black/10 px-4 py-3 text-right">
                  <p class="text-3xl font-590 tabular-nums text-current">
                    {@summary.completion_percent}%
                  </p>
                  <p class="mt-1 text-[10px] font-590 uppercase tracking-[0.12em] text-current/70">
                    Completed
                  </p>
                </div>
              </div>

              <div class="mt-4 h-2 overflow-hidden rounded-full bg-black/10">
                <div
                  class="progress-spring h-full rounded-full bg-current/80"
                  style={progress_bar_fill(@summary)}
                >
                </div>
              </div>

              <%!-- The blocked titles were listed here, again in the Blocked work
                   panel, and a third time in the item list. The Blocked work
                   panel is the one with the unblock affordance, so it keeps them. --%>
              <div class="mt-4 grid gap-3 sm:grid-cols-4">
                <div class="rounded-xl border border-current/15 bg-black/10 px-3 py-3">
                  <p class="text-[10px] font-590 uppercase tracking-[0.12em] text-current/65">
                    Total
                  </p>
                  <p class="mt-1 text-2xl font-590 tabular-nums text-current">{@summary.total}</p>
                </div>
                <div class="rounded-xl border border-current/15 bg-black/10 px-3 py-3">
                  <p class="text-[10px] font-590 uppercase tracking-[0.12em] text-current/65">
                    Open
                  </p>
                  <p class="mt-1 text-2xl font-590 tabular-nums text-current">
                    {@summary.open_count}
                  </p>
                </div>
                <div class="rounded-xl border border-current/15 bg-black/10 px-3 py-3">
                  <p class="text-[10px] font-590 uppercase tracking-[0.12em] text-current/65">
                    Blocked
                  </p>
                  <p class="mt-1 text-2xl font-590 tabular-nums text-current">
                    {@summary.blocked_count}
                  </p>
                </div>
                <div class="rounded-xl border border-current/15 bg-black/10 px-3 py-3">
                  <p class="text-[10px] font-590 uppercase tracking-[0.12em] text-current/65">
                    Completed
                  </p>
                  <p class="mt-1 text-2xl font-590 tabular-nums text-current">
                    {@summary.completed_count}
                  </p>
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-border bg-panel p-5 shadow-card">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h2
                    class="text-lg font-590 text-text-primary"
                    title="Capture a title, owner, status, and blocked state in one pass."
                  >
                    Add work to the tracker<span class="sr-only">
                      — capture a title, owner, status, and blocked state in one pass.</span>
                  </h2>
                </div>
              </div>

              <.simple_form
                for={@form}
                id="launch-item-create-form"
                phx-submit="create_launch_item"
                class="mt-5 space-y-4"
              >
                <.input
                  field={@form[:title]}
                  label="Title"
                  required
                  placeholder="Ship launch checklist, QA signoff, or release comms"
                />

                <div class="grid gap-4 sm:grid-cols-2">
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
                </div>

                <.input field={@form[:is_blocked]} type="checkbox" label="Blocked" />

                <div class="flex justify-end">
                  <.button type="submit" variant="primary">Create launch item</.button>
                </div>
              </.simple_form>
            </div>
          </section>

          <section class="space-y-4">
            <div
              :if={@summary.total > 0}
              id="blocked-work-view"
              class="rounded-2xl border border-border bg-panel p-5 shadow-card"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <h2 class="text-lg font-590 text-text-primary">Blocked work</h2>

                <span class="rounded-full border border-rose-500/25 bg-rose-500/10 px-3 py-1 text-xs font-590 text-rose-300">
                  {@summary.blocked_count} blocked
                </span>
              </div>

              <div
                :if={blocked_items(@launch_items) == []}
                class="mt-5 rounded-2xl border border-dashed border-border/80 bg-surface/40 px-5 py-6 text-center"
              >
                <p class="text-sm font-590 text-text-primary">No blocked launch items.</p>
                <p class="mt-1 text-sm leading-6 text-text-tertiary">
                  Blocked items appear here as soon as they are marked.
                </p>
              </div>

              <div :if={blocked_items(@launch_items) != []} class="stagger-children mt-5 space-y-3">
                <article
                  :for={item <- blocked_items(@launch_items)}
                  id={"blocked-launch-item-#{item.id}"}
                  class="card-lift rounded-xl border border-rose-500/20 bg-rose-500/10 px-4 py-3"
                >
                  <%!-- Owner and status are already on this item's row in the
                       list below, next to the controls that change them. --%>
                  <h3
                    class="truncate text-sm font-590 text-rose-100"
                    title={"#{status_label(item.status)} · #{owner_label(item.owner_user)}"}
                  >
                    {item.title}
                  </h3>
                </article>
              </div>
            </div>

            <div class="rounded-2xl border border-border bg-panel p-5 shadow-card">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <h2 class="text-lg font-590 text-text-primary">Everything on the tracker</h2>

                <span class="rounded-full border border-border bg-surface px-3 py-1 text-xs font-590 text-text-secondary">
                  {@summary.total} item{if @summary.total == 1, do: "", else: "s"}
                </span>
              </div>

              <div
                :if={Enum.empty?(@launch_items)}
                class="mt-6 rounded-2xl border border-dashed border-border/80 bg-surface/40 px-5 py-10 text-center"
              >
                <p class="text-base font-590 text-text-primary">No launch items yet.</p>
                <p class="mt-2 text-sm leading-6 text-text-tertiary">
                  Use the form to create the first item and start tracking readiness.
                </p>
              </div>

              <div :if={!Enum.empty?(@launch_items)} class="stagger-children mt-5 space-y-3">
                <article
                  :for={item <- @launch_items}
                  id={"launch-item-#{item.id}"}
                  class={[
                    "group card-lift rounded-2xl border p-4 shadow-sm transition-colors",
                    launch_card_class(item)
                  ]}
                >
                  <div class="flex items-start justify-between gap-3">
                    <div class="min-w-0">
                      <div class="flex min-w-0 items-center gap-2">
                        <span
                          class={["h-2 w-2 shrink-0 rounded-full", launch_status_dot(item.status)]}
                          title={"Status: #{status_label(item.status)}"}
                        >
                        </span>
                        <h3 class="truncate text-base font-590 text-text-primary">
                          {item.title}
                        </h3>
                      </div>
                      <%!-- The owner select two lines down shows the same name
                           and is the control that changes it. --%>
                    </div>

                    <button
                      type="button"
                      phx-click="toggle_blocked"
                      phx-value-id={item.id}
                      class={[
                        "shrink-0 rounded-full border px-3 py-1.5 text-xs font-590 transition",
                        blocked_badge_class(item.is_blocked),
                        unless(item.is_blocked,
                          do: "opacity-70 group-hover:opacity-100 focus:opacity-100"
                        )
                      ]}
                    >
                      {blocked_toggle_label(item.is_blocked)}
                    </button>
                  </div>

                  <div class="mt-4 grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1fr)] md:items-end">
                    <form
                      id={"launch-item-owner-#{item.id}"}
                      phx-change="update_owner"
                      class="space-y-1"
                    >
                      <input type="hidden" name="_id" value={item.id} />
                      <%!-- "Owner" and "Status" were printed above every row's
                           controls; the controls say what they are. --%>
                      <select
                        name="owner_user_id"
                        aria-label="Owner"
                        title="Owner"
                        class="w-full rounded-lg border border-border bg-panel px-3 py-2 text-sm text-text-primary outline-none transition focus:border-brand focus:ring-2 focus:ring-brand/20"
                      >
                        <option
                          :for={{label, value} <- owner_options(@company_members)}
                          value={value}
                          selected={value == item.owner_user_id}
                        >
                          {label}
                        </option>
                      </select>
                    </form>

                    <div class="space-y-1">
                      <div
                        role="group"
                        aria-label="Status"
                        title="Status"
                        class="flex flex-wrap gap-2"
                      >
                        <button
                          type="button"
                          phx-click="update_status"
                          phx-value-id={item.id}
                          phx-value-status="planned"
                          class={[
                            "rounded-full border px-3 py-1.5 text-xs font-590 transition",
                            status_button_class(item.status, "planned")
                          ]}
                        >
                          Planned
                        </button>
                        <button
                          type="button"
                          phx-click="update_status"
                          phx-value-id={item.id}
                          phx-value-status="in_progress"
                          class={[
                            "rounded-full border px-3 py-1.5 text-xs font-590 transition",
                            status_button_class(item.status, "in_progress")
                          ]}
                        >
                          In progress
                        </button>
                        <button
                          type="button"
                          phx-click="update_status"
                          phx-value-id={item.id}
                          phx-value-status="completed"
                          class={[
                            "rounded-full border px-3 py-1.5 text-xs font-590 transition",
                            status_button_class(item.status, "completed")
                          ]}
                        >
                          Completed
                        </button>
                      </div>
                    </div>
                  </div>

                  <%!-- This row restated the status a third time: the dot next to
                       the title carries it, the highlighted Status button carries
                       it, and the Unblock/Mark blocked button carries blocked. --%>
                </article>
              </div>
            </div>
          </section>
        </div>
      </div>
    </.page>
    """
  end

  defp assign_tracker(socket) do
    company = current_company(socket)
    members = company_members(company)
    launch_items = company_launch_items(company)
    summary = company_launch_summary(company)

    socket
    |> assign(:page_title, "Launch Tracker")
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
  def status_label("in_progress"), do: "In Progress"
  def status_label("completed"), do: "Completed"

  def owner_options(company_members) do
    Enum.map(company_members, fn membership ->
      {member_label(membership.user), membership.user.id}
    end)
  end

  def owner_label(nil), do: "Unassigned"
  def owner_label(user), do: member_label(user)

  def blocked_items(items), do: Enum.filter(items, & &1.is_blocked)

  def member_label(%{name: name, email: email}) when is_binary(name) and name != "" do
    "#{name} · #{email}"
  end

  def member_label(%{email: email}), do: email

  def blocked_badge_class(true), do: "border-rose-500/30 bg-rose-500/10 text-rose-300"
  def blocked_badge_class(false), do: "border-border bg-surface text-text-tertiary"

  def status_button_class(current_status, status) do
    if current_status == status do
      "border-brand/40 bg-brand/10 text-brand"
    else
      "border-border bg-panel text-text-secondary hover:bg-surface-hover hover:text-text-primary"
    end
  end

  def summary_tone_class(:danger), do: "border-rose-500/25 bg-rose-500/10 text-rose-200"
  def summary_tone_class(:ok), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200"
  def summary_tone_class(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  def summary_tone_class(:empty), do: "border-border bg-surface/70 text-text-secondary"
  def summary_tone_class(_), do: "border-border bg-surface/70 text-text-primary"

  def progress_bar_fill(summary) do
    "width: #{summary.completion_percent}%"
  end

  def blocked_toggle_label(true), do: "Unblock"
  def blocked_toggle_label(false), do: "Mark blocked"

  # Blocked wins (act-now, quiet rose); completed settles back; else neutral.
  def launch_card_class(%{is_blocked: true}), do: "border-rose-500/25 bg-rose-500/[0.04]"
  def launch_card_class(%{status: "completed"}), do: "border-border/70 bg-surface/40 opacity-80"
  def launch_card_class(_), do: "border-border bg-surface/70"

  def launch_status_dot("completed"), do: "bg-emerald-400/70"
  def launch_status_dot("in_progress"), do: "bg-sky-400/70"
  def launch_status_dot(_), do: "bg-text-quaternary/40"
end
