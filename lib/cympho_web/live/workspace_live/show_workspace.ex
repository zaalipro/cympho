defmodule CymphoWeb.WorkspaceLive.ShowWorkspace do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @bad_service_health ~w(degraded failing failed unhealthy error)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    with {:ok, workspace} <- Workspaces.get_project_workspace(id),
         true <- own_company?(socket, workspace) do
      execution_workspaces = Workspaces.list_execution_workspaces(id)
      runtime_services = Workspaces.list_runtime_services_for_project_workspace(id)

      {:ok,
       socket
       |> assign(:page_title, "Workspace: #{workspace.name}")
       |> assign(:workspace, workspace)
       |> assign(:execution_workspaces, execution_workspaces)
       |> assign(:runtime_services, runtime_services)
       |> assign(
         :workspace_command,
         workspace_command(workspace, execution_workspaces, runtime_services)
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Workspace not found")
         |> push_navigate(to: ~p"/workspaces")}
    end
  end

  defp own_company?(socket, %{company_id: company_id}) do
    match?(%{id: ^company_id}, socket.assigns[:current_company])
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page size="wide" data-ui-complex-page>
      <%!-- The subtitle named the three panels the page already shows. It stays
           on hover and for screen readers. --%>
      <.header>
        <h1
          class="flex items-center gap-2 text-headline text-text-primary"
          title="Project workspace command center for execution lanes, previews, and reusable runtime services."
        >
          <span class="min-w-0 truncate">{@workspace.name}</span>
          <span class="sr-only">
            — project workspace command center for execution lanes, previews, and reusable runtime services.
          </span>
        </h1>
        <:actions>
          <.app_link
            navigate={~p"/workspaces"}
            class="inline-flex items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
          >
            <.icon name="hero-arrow-left-mini" class="h-4 w-4" /> Workspaces
          </.app_link>
        </:actions>
      </.header>

      <section
        data-testid="project-workspace-command"
        class="mb-5 overflow-hidden rounded-lg border border-border bg-panel shadow-card"
      >
        <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <p class="text-[11px] font-590 uppercase tracking-[0.14em] text-text-quaternary">
                Project workspace
              </p>
              <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{workspace_command_badge_class(@workspace_command.tone)}"}>
                {@workspace_command.badge}
              </span>
              <span
                :if={@workspace.is_primary}
                class="rounded-full border border-brand/25 bg-brand/10 px-2 py-0.5 text-[11px] font-510 text-brand"
              >
                Primary
              </span>
            </div>

            <%!-- The detail sentence spelled out the same counts as the metric
                 strip below and the same next step as the panel empty states. --%>
            <h2 class="mt-2 text-lg font-590 text-text-primary" title={@workspace_command.detail}>
              {@workspace_command.heading}<span class="sr-only">
                — {@workspace_command.detail}</span>
            </h2>

            <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2 text-xs">
              <span class="max-w-full truncate rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary">
                {workspace_location(@workspace)}
              </span>
              <span
                :if={workspace_ref(@workspace)}
                class="rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary"
              >
                {workspace_ref(@workspace)}
              </span>
              <span
                :if={@workspace.source_type}
                class="rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary"
              >
                {@workspace.source_type}
              </span>
            </div>
          </div>

          <.app_link
            navigate={@workspace_command.action_path}
            class={"inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-590 transition-colors #{workspace_command_action_class(@workspace_command.tone)}"}
          >
            <.icon name="hero-arrow-right-mini" class="h-4 w-4" />
            {@workspace_command.action_label}
          </.app_link>
        </div>

        <div class="ui-advanced-only grid grid-cols-2 border-t border-border sm:grid-cols-4">
          <.workspace_detail_metric
            :for={metric <- @workspace_command.metrics}
            label={metric.label}
            value={metric.value}
            tone={metric.tone}
          />
        </div>
      </section>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.15fr)_minmax(360px,0.85fr)]">
        <section class="overflow-hidden rounded-lg border border-border bg-panel">
          <div class="border-b border-border px-4 py-3">
            <p
              class="text-sm font-590 text-text-primary"
              title="Open lanes are worktrees or isolated directories where agents can make changes."
            >
              Execution lanes<span class="sr-only">
                — open lanes are worktrees or isolated directories where agents can make changes.</span>
            </p>
          </div>

          <div :if={!Enum.empty?(@execution_workspaces)} class="divide-y divide-border">
            <.app_link
              :for={ew <- @execution_workspaces}
              navigate={~p"/workspaces/#{@workspace.id}/exec/#{ew.id}"}
              class="group block p-4 hover:bg-surface-hover"
            >
              <div class="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate text-sm font-590 text-text-primary">{ew.name}</h3>
                    <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{execution_status_badge_class(ew.status)}"}>
                      {status_label(ew.status)}
                    </span>
                  </div>
                  <p class="mt-1 truncate text-xs text-text-tertiary">
                    {execution_detail(ew)}
                  </p>
                </div>

                <div class="flex shrink-0 items-center gap-2 text-xs text-text-quaternary">
                  <span :if={ew.mode} class="rounded-full border border-border bg-surface px-2 py-1">
                    {ew.mode}
                  </span>
                  <span
                    :if={ew.branch_name}
                    class="rounded-full border border-border bg-surface px-2 py-1"
                  >
                    {ew.branch_name}
                  </span>
                  <.icon
                    name="hero-arrow-right-mini"
                    class="h-4 w-4 opacity-0 transition-opacity group-hover:opacity-100"
                  />
                </div>
              </div>
            </.app_link>
          </div>

          <.empty_state
            :if={Enum.empty?(@execution_workspaces)}
            title="No execution lanes"
            message="Assign an issue to an agent and one opens here."
          >
            <:icon_slot>
              <.icon name="hero-square-3-stack-3d-mini" class="h-5 w-5" />
            </:icon_slot>
          </.empty_state>
        </section>

        <section class="overflow-hidden rounded-lg border border-border bg-panel">
          <div class="border-b border-border px-4 py-3">
            <p
              class="text-sm font-590 text-text-primary"
              title="Running services with a port or URL can be inspected from previews."
            >
              Runtime services<span class="sr-only">
                — running services with a port or URL can be inspected from previews.</span>
            </p>
          </div>

          <div :if={!Enum.empty?(@runtime_services)} class="divide-y divide-border">
            <div :for={svc <- @runtime_services} class="p-4">
              <div class="flex min-w-0 items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate text-sm font-590 text-text-primary">{svc.service_name}</h3>
                    <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{service_status_badge_class(svc)}"}>
                      {status_label(svc.status)}
                    </span>
                  </div>
                  <p class="mt-1 truncate text-xs text-text-tertiary">
                    {service_detail(svc)}
                  </p>
                </div>

                <div
                  :if={preview_href(svc) || connection_string(svc)}
                  id={"ws-svc-conn-#{svc.id}"}
                  phx-hook="CopyToClipboard"
                  class="flex shrink-0 items-center gap-2"
                >
                  <button
                    :if={connection_string(svc)}
                    type="button"
                    data-copy-text={connection_string(svc)}
                    data-copy-success-label="Copied"
                    class="inline-flex items-center gap-1.5 rounded-lg border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                  >
                    <.icon name="hero-clipboard-document" class="h-3.5 w-3.5" /> Copy
                  </button>
                  <a
                    :if={preview_href(svc)}
                    href={preview_href(svc)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex shrink-0 items-center gap-1.5 rounded-lg border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                  >
                    <.icon name="hero-arrow-top-right-on-square-mini" class="h-3.5 w-3.5" /> Preview
                  </a>
                </div>
              </div>
            </div>
          </div>

          <.empty_state
            :if={Enum.empty?(@runtime_services)}
            title="No runtime services"
            message="Start a dev server in a lane and it shows up here."
          >
            <:icon_slot>
              <.icon name="hero-bolt-mini" class="h-5 w-5" />
            </:icon_slot>
          </.empty_state>
        </section>
      </div>
    </.page>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def workspace_detail_metric(assigns) do
    ~H"""
    <div class="border-r border-border px-4 py-3 last:border-r-0">
      <p class="text-[10px] font-590 uppercase leading-3 tracking-[0.12em] text-text-quaternary">
        {@label}
      </p>
      <p class={"mt-1 font-mono text-xl font-590 leading-none tabular-nums #{metric_text(@tone)}"}>
        {@value}
      </p>
    </div>
    """
  end

  defp workspace_command(_workspace, execution_workspaces, runtime_services) do
    metrics = workspace_metrics(execution_workspaces, runtime_services)
    tone = workspace_tone(metrics)

    %{
      tone: tone,
      badge: workspace_badge(tone),
      heading: workspace_heading(tone),
      detail: workspace_detail(tone, metrics),
      action_label: workspace_action_label(tone),
      action_path: workspace_action_path(tone),
      metrics: [
        %{
          label: "Open lanes",
          value: metrics.open_execution_workspaces,
          tone: count_tone(metrics.open_execution_workspaces, :ok)
        },
        %{
          label: "Services",
          value: metrics.running_services,
          tone: count_tone(metrics.running_services, :ok)
        },
        %{
          label: "Preview gaps",
          value: metrics.previewless_services,
          tone: count_tone(metrics.previewless_services, :warning)
        },
        %{
          label: "Unhealthy",
          value: metrics.unhealthy_services,
          tone: count_tone(metrics.unhealthy_services, :critical)
        }
      ]
    }
  end

  defp workspace_metrics(execution_workspaces, runtime_services) do
    running_services = Enum.filter(runtime_services, &(&1.status == "running"))

    %{
      open_execution_workspaces:
        Enum.count(execution_workspaces, &(&1.status in ["open", "running", "active"])),
      running_services: length(running_services),
      previewless_services: Enum.count(running_services, &previewless_service?/1),
      unhealthy_services: Enum.count(runtime_services, &unhealthy_service?/1)
    }
  end

  defp workspace_tone(%{unhealthy_services: count}) when count > 0, do: :critical
  defp workspace_tone(%{previewless_services: count}) when count > 0, do: :warning

  defp workspace_tone(%{open_execution_workspaces: open, running_services: services})
       when open > 0 or services > 0,
       do: :healthy

  defp workspace_tone(_metrics), do: :idle

  defp workspace_badge(:critical), do: "Repair"
  defp workspace_badge(:warning), do: "Inspect"
  defp workspace_badge(:healthy), do: "Ready"
  defp workspace_badge(:idle), do: "Idle"

  defp workspace_heading(:critical), do: "Runtime needs repair before this workspace is reused"
  defp workspace_heading(:warning), do: "Expose previews before relying on this workspace"
  defp workspace_heading(:healthy), do: "This workspace is ready for delegated execution"
  defp workspace_heading(:idle), do: "This workspace is configured but not running"

  defp workspace_detail(:critical, metrics) do
    "#{metrics.unhealthy_services} runtime service(s) report failed, degraded, or unhealthy status."
  end

  defp workspace_detail(:warning, metrics) do
    "#{metrics.previewless_services} running service(s) need a port or URL before owners can inspect previews."
  end

  defp workspace_detail(:healthy, metrics) do
    "#{metrics.open_execution_workspaces} execution lane(s) and #{metrics.running_services} running service(s) are available."
  end

  defp workspace_detail(:idle, _metrics) do
    "No execution lane or runtime service is active. Assign work to an agent to create one."
  end

  defp workspace_action_label(:critical), do: "Open operations"
  defp workspace_action_label(:warning), do: "Open operations"
  defp workspace_action_label(:healthy), do: "Open operations"
  defp workspace_action_label(:idle), do: "All workspaces"

  defp workspace_action_path(:idle), do: "/workspaces"
  defp workspace_action_path(_tone), do: "/operations"

  defp workspace_command_badge_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp workspace_command_badge_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp workspace_command_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp workspace_command_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp workspace_command_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-100 hover:bg-red-500/15"

  defp workspace_command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp workspace_command_action_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/15"

  defp workspace_command_action_class(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp execution_status_badge_class(status) when status in ["open", "running", "active"],
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp execution_status_badge_class(status) when status in ["failed", "error"],
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp execution_status_badge_class(status) when status in ["closed", "cleaned_up"],
    do: "border-border bg-surface text-text-tertiary"

  defp execution_status_badge_class(_status),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp service_status_badge_class(service) do
    cond do
      unhealthy_service?(service) ->
        "border-red-500/25 bg-red-500/10 text-red-300"

      service.status == "running" ->
        "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

      true ->
        "border-border bg-surface text-text-tertiary"
    end
  end

  defp metric_text(:critical), do: "text-red-300"
  defp metric_text(:warning), do: "text-amber-300"
  defp metric_text(:ok), do: "text-emerald-300"
  defp metric_text(_), do: "text-text-primary"

  defp count_tone(0, _tone), do: :neutral
  defp count_tone(_count, tone), do: tone

  defp unhealthy_service?(service) do
    service.status in ["failed", "error"] or service.health_status in @bad_service_health
  end

  defp previewless_service?(service),
    do: not Cympho.Workspaces.PreviewUrl.previewable?(service)

  defp blank?(value), do: is_nil(value) or value == ""

  defp workspace_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp workspace_location(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "",
    do: repo_url

  defp workspace_location(_workspace), do: "No path or repository configured"

  defp workspace_ref(%{default_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(%{repo_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(_workspace), do: nil

  defp execution_detail(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp execution_detail(%{base_ref: base_ref}) when is_binary(base_ref) and base_ref != "",
    do: base_ref

  defp execution_detail(_workspace), do: "No execution path recorded"

  defp service_detail(service) do
    [
      service.url,
      service_port(service),
      service.health_status,
      service.provider
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No preview endpoint or provider metadata recorded"
      parts -> Enum.join(parts, " | ")
    end
  end

  defp service_port(%{port: nil}), do: nil
  defp service_port(%{port: port}), do: ":#{port}"

  defp preview_href(service),
    do: Cympho.Workspaces.PreviewUrl.generate_preview_url(service, "")

  defp connection_string(%{url: url}) when is_binary(url) and url != "", do: url
  defp connection_string(%{port: port}) when is_integer(port), do: "localhost:#{port}"
  defp connection_string(_service), do: nil

  defp status_label(nil), do: "Unknown"

  defp status_label(status) do
    status
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
