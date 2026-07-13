defmodule CymphoWeb.PluginLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Skills, Companies, Plugins}

  @filter_statuses ~w(installed active disabled error)

  @impl true
  def mount(_params, _session, socket) do
    companies = Companies.list_companies()

    {:ok,
     socket
     |> assign(:companies, companies)
     |> assign(:selected_company_id, nil)
     |> assign(:selected_status, nil)
     |> assign(:plugin_health, Plugins.health_summary())
     |> assign(:infinite_scroll, %{})
     |> assign(:page_title, "Plugins")}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    company_id = normalize_company_filter(params["company_id"], socket.assigns.companies)
    status = normalize_status_filter(params["status"])

    socket =
      socket
      |> assign(:page_title, "Plugins")
      |> assign(:plugin, nil)
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_status, status)
      |> assign(:plugin_health, Plugins.health_summary(company_id))

    init_stream(socket, :plugins, &fetch_plugins(socket, &1))
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter", %{"company_id" => company_id, "status" => status}, socket) do
    company_id = normalize_company_filter(company_id, socket.assigns.companies)
    status = normalize_status_filter(status)

    socket =
      socket
      |> assign(:selected_company_id, company_id)
      |> assign(:selected_status, status)
      |> assign(:plugin_health, Plugins.health_summary(company_id))

    {:noreply, reset_stream(socket, :plugins, &fetch_plugins(socket, &1))}
  end

  @impl true
  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :plugins, &fetch_plugins(socket, &1))}
  end

  @impl true
  def handle_event("toggle_plugin", %{"id" => id}, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        case Skills.toggle_plugin(plugin) do
          {:ok, updated_plugin} ->
            {:noreply,
             socket
             |> stream_insert(:plugins, updated_plugin)
             |> refresh_plugin_health()
             |> put_flash(
               :info,
               "Plugin #{if updated_plugin.enabled, do: "enabled", else: "disabled"}"
             )}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to toggle plugin")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Plugin not found")}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    case fetch_company_plugin(socket, id) do
      {:ok, plugin} ->
        case Skills.delete_plugin(plugin) do
          {:ok, deleted} ->
            {:noreply,
             socket
             |> stream_delete(:plugins, deleted)
             |> refresh_plugin_health()
             |> put_flash(:info, "Plugin deleted successfully")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to delete plugin")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Plugin not found")}
    end
  end

  defp fetch_plugins(socket, cursor) do
    Skills.list_plugins_page(
      company_id: socket.assigns[:selected_company_id],
      status: socket.assigns[:selected_status],
      after: cursor
    )
  end

  defp normalize_company_filter(company_id, companies) when is_binary(company_id) do
    company_id = String.trim(company_id)

    cond do
      company_id == "" -> nil
      Enum.any?(companies, &(&1.id == company_id)) -> company_id
      true -> nil
    end
  end

  defp normalize_company_filter(_company_id, _companies), do: nil

  defp normalize_status_filter(status) when status in @filter_statuses, do: status
  defp normalize_status_filter(_status), do: nil

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp refresh_plugin_health(socket) do
    assign(socket, :plugin_health, Plugins.health_summary(socket.assigns[:selected_company_id]))
  end

  def status_label(nil), do: "Unknown"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def plugin_error?(%{status: "error"}), do: true
  def plugin_error?(_plugin), do: false

  attr :enabled, :boolean, required: true

  def plugin_state(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-510",
      (@enabled && "text-text-tertiary") || "text-text-quaternary"
    ]}>
      <span class={[
        "h-1.5 w-1.5 rounded-full",
        (@enabled && "bg-emerald-400/80") || "bg-text-quaternary/60"
      ]}>
      </span>
      {(@enabled && "Enabled") || "Disabled"}
    </span>
    """
  end

  def humanize_capability(capability) do
    capability
    |> to_string()
    |> String.replace(["_", ":", "-", "."], " ")
    |> String.trim()
  end

  def humanized_capabilities(capabilities) when is_list(capabilities) do
    capabilities
    |> Enum.map(&humanize_capability/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def humanized_capabilities(_capabilities), do: ""

  def company_name(%{company: %{name: name}}) when is_binary(name), do: name
  def company_name(_), do: "Global"

  def project_name(%{project: %{name: name}}) when is_binary(name), do: name
  def project_name(_), do: "All projects"

  def capability_count(capabilities) when is_list(capabilities), do: length(capabilities)
  def capability_count(_), do: 0

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def plugin_health_metric(assigns) do
    ~H"""
    <div class="bg-surface/70 px-3 py-2 text-center">
      <p class={"font-mono text-[18px] font-590 leading-none #{plugin_metric_text(@tone)}"}>
        {@value}
      </p>
      <p class="mt-1 text-[10px] uppercase tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
    </div>
    """
  end

  def plugin_health_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def plugin_health_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  def plugin_health_badge(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  def plugin_health_badge(:empty), do: "border-border bg-surface text-text-tertiary"
  def plugin_health_badge(_), do: "border-border bg-surface text-text-tertiary"

  def plugin_metric_text(:critical), do: "text-red-300"
  def plugin_metric_text(:warning), do: "text-amber-300"
  def plugin_metric_text(:ok), do: "text-emerald-300"
  def plugin_metric_text(_), do: "text-text-primary"

  def plugin_recommendation_class(:critical), do: "border-red-500/20 bg-red-500/10 text-red-100"

  def plugin_recommendation_class(:warning),
    do: "border-amber-500/20 bg-amber-500/10 text-amber-100"

  def plugin_recommendation_class(_), do: "border-border bg-surface text-text-secondary"

  def plugin_posture_label(:empty), do: "Setup posture"
  def plugin_posture_label(_level), do: "Runtime posture"

  def plugin_posture_text(:empty) do
    "No extensions are installed yet. Add one plugin, scope its capabilities, then watch worker logs and webhooks here."
  end

  def plugin_posture_text(_level) do
    "Supervision, capability scope, webhooks, and recent plugin logs are quiet."
  end

  def plugin_next_action_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-100"
  def plugin_next_action_class(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-100"

  def plugin_next_action_class(:ok),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100"

  def plugin_next_action_class(_), do: "border-border bg-surface text-text-secondary"

  def plugin_next_action_path(%{key: :install_first_plugin}), do: "/plugins/marketplace"
  def plugin_next_action_path(%{key: :review_marketplace}), do: "/plugins/marketplace"

  def plugin_next_action_path(%{key: :start_supervisor}),
    do: "/operations#runtime-launch-checklist"

  def plugin_next_action_path(%{key: :repair_manifests}), do: "/plugins?status=error"
  def plugin_next_action_path(%{key: :audit_disabled_plugins}), do: "/plugins?status=disabled"
  def plugin_next_action_path(_action), do: "/plugins"

  def plugin_filters_active?(company_id, status),
    do: company_id not in [nil, ""] or status not in [nil, ""]

  def plugin_empty_icon(company_id, status) do
    if plugin_filters_active?(company_id, status),
      do: "hero-funnel-mini",
      else: "hero-puzzle-piece-mini"
  end

  def plugin_empty_title(company_id, status) do
    if plugin_filters_active?(company_id, status),
      do: "No plugins match these filters",
      else: "No runtime plugins installed yet"
  end

  def plugin_empty_detail(company_id, status) do
    if plugin_filters_active?(company_id, status) do
      "Clear filters to return to the full extension inventory, or open the marketplace if this capability still needs to be installed."
    else
      "Install one tightly scoped extension, verify its manifest and capability boundary, then watch health and webhook evidence here."
    end
  end

  def plugin_empty_action_class(:primary) do
    "inline-flex h-8 items-center justify-center rounded-lg bg-primary px-3 text-xs font-510 text-white transition-colors hover:bg-primary-hover"
  end

  def plugin_empty_action_class(_tone) do
    "inline-flex h-8 items-center justify-center rounded-lg border border-border bg-surface px-3 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end
end
