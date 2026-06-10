defmodule CymphoWeb.PluginLive.Index do
  use CymphoWeb, :live_view

  alias Cympho.{Skills, Companies, Plugins}

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

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Plugins")
    |> assign(:plugin, nil)
    |> init_stream(:plugins, &fetch_plugins(socket, &1))
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("filter", %{"company_id" => company_id, "status" => status}, socket) do
    company_id = if company_id == "", do: nil, else: company_id
    status = if status == "", do: nil, else: status

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

  defp fetch_company_plugin(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Skills.get_company_plugin(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp refresh_plugin_health(socket) do
    assign(socket, :plugin_health, Plugins.health_summary(socket.assigns[:selected_company_id]))
  end

  def status_class("active"), do: "border-success/20 bg-success/10 text-success"
  def status_class("installed"), do: "border-brand/20 bg-brand/10 text-brand"

  def status_class("disabled"),
    do: "border-text-quaternary/20 bg-text-quaternary/10 text-text-tertiary"

  def status_class("error"), do: "border-brand/20 bg-brand/10 text-brand"
  def status_class(_), do: "border-border bg-surface text-text-tertiary"

  def status_label(nil), do: "Unknown"

  def status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def enabled_label(true), do: "Enabled"
  def enabled_label(false), do: "Disabled"
  def enabled_label(_), do: "Unknown"

  def enabled_class(true), do: "text-success"
  def enabled_class(false), do: "text-text-quaternary"
  def enabled_class(_), do: "text-text-tertiary"

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
end
