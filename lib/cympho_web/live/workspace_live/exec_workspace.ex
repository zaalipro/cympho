defmodule CymphoWeb.WorkspaceLive.ExecWorkspace do
  use CymphoWeb, :live_view
  alias Cympho.Workspaces

  @bad_service_health ~w(degraded failing failed unhealthy error)
  @bad_probe_statuses ~w(failed error unhealthy)

  @impl true
  def mount(%{"exec_id" => id}, _session, socket) do
    with {:ok, workspace} <- Workspaces.get_execution_workspace(id),
         true <- own_company?(socket, workspace) do
      runtime_services = Workspaces.list_runtime_services(id)
      operations = Workspaces.list_operations(id)
      leases = Workspaces.list_leases_for_execution_workspace(id)
      probes = Workspaces.list_probes_for_workspace(id)

      {:ok,
       socket
       |> assign(:page_title, "Exec Workspace: #{workspace.name}")
       |> assign(:workspace, workspace)
       |> assign(:runtime_services, runtime_services)
       |> assign(:operations, operations)
       |> assign(:leases, leases)
       |> assign(:probes, probes)
       |> assign(
         :runtime_command,
         runtime_command(workspace, runtime_services, operations, leases, probes)
       )}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Execution workspace not found")
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
    <.page size="wide">
      <.header
        title={@workspace.name}
        subtitle="Execution lane details for services, previews, probes, leases, and operation history."
      >
        <:actions>
          <.app_link
            navigate={~p"/workspaces/#{@workspace.project_workspace_id}"}
            class="inline-flex items-center gap-2 rounded-lg border border-border bg-surface px-3 py-2 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
          >
            <.icon name="hero-arrow-left-mini" class="h-4 w-4" /> Project workspace
          </.app_link>
        </:actions>
      </.header>

      <section
        data-testid="execution-workspace-command"
        class="mb-5 overflow-hidden rounded-lg border border-border bg-panel shadow-card"
      >
        <div class="grid gap-4 p-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <p class="text-[11px] font-590 uppercase tracking-[0.14em] text-text-quaternary">
                Execution command
              </p>
              <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{command_badge_class(@runtime_command.tone)}"}>
                {@runtime_command.badge}
              </span>
              <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{execution_status_badge_class(@workspace.status)}"}>
                {status_label(@workspace.status)}
              </span>
            </div>

            <h2 class="mt-2 text-lg font-590 text-text-primary">
              {@runtime_command.heading}
            </h2>
            <p class="mt-1 max-w-3xl text-sm leading-6 text-text-tertiary">
              {@runtime_command.detail}
            </p>

            <div class="mt-3 flex min-w-0 flex-wrap items-center gap-2 text-xs">
              <span
                :if={@workspace.branch_name}
                class="rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary"
              >
                {@workspace.branch_name}
              </span>
              <span
                :if={@workspace.mode}
                class="rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary"
              >
                {@workspace.mode}
              </span>
              <span class="max-w-full truncate rounded-full border border-border bg-surface px-2 py-1 text-text-tertiary">
                {execution_location(@workspace)}
              </span>
            </div>
          </div>

          <.app_link
            navigate="/operations#runtime-launch-checklist"
            class={"inline-flex shrink-0 items-center justify-center gap-2 rounded-lg border px-3 py-2 text-sm font-590 transition-colors #{command_action_class(@runtime_command.tone)}"}
          >
            <.icon name="hero-command-line-mini" class="h-4 w-4" /> Runtime checklist
          </.app_link>
        </div>

        <div class="grid grid-cols-2 border-t border-border sm:grid-cols-3 lg:grid-cols-6">
          <.runtime_metric
            :for={metric <- @runtime_command.metrics}
            label={metric.label}
            value={metric.value}
            tone={metric.tone}
          />
        </div>
      </section>

      <div class="grid gap-5 xl:grid-cols-[minmax(0,1.05fr)_minmax(360px,0.95fr)]">
        <section class="overflow-hidden rounded-lg border border-border bg-panel">
          <div class="border-b border-border px-4 py-3">
            <p class="text-sm font-590 text-text-primary">Runtime services</p>
            <p class="mt-1 text-xs leading-5 text-text-tertiary">
              Services with ports or URLs can be opened for owner inspection.
            </p>
          </div>

          <div :if={!Enum.empty?(@runtime_services)} class="divide-y divide-border">
            <div :for={svc <- @runtime_services} class="p-4">
              <div class="flex min-w-0 flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate text-sm font-590 text-text-primary">{svc.service_name}</h3>
                    <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{service_status_badge_class(svc)}"}>
                      {status_label(svc.status)}
                    </span>
                    <span
                      :if={svc.health_status}
                      class="rounded-full border border-border bg-surface px-2 py-0.5 text-[11px] font-510 text-text-tertiary"
                    >
                      {status_label(svc.health_status)}
                    </span>
                  </div>

                  <p class="mt-1 truncate text-xs text-text-tertiary">
                    {service_detail(svc)}
                  </p>
                  <p :if={svc.command} class="mt-2 truncate font-mono text-xs text-text-quaternary">
                    {svc.command}
                  </p>
                </div>

                <div
                  :if={preview_href(svc) || connection_string(svc)}
                  id={"exec-svc-conn-#{svc.id}"}
                  phx-hook="CopyToClipboard"
                  class="flex shrink-0 items-center gap-2"
                >
                  <button
                    :if={connection_string(svc)}
                    type="button"
                    data-copy-text={connection_string(svc)}
                    data-copy-success-label="Copied"
                    class="inline-flex items-center justify-center gap-1.5 rounded-lg border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                  >
                    <.icon name="hero-clipboard-document" class="h-3.5 w-3.5" /> Copy
                  </button>
                  <a
                    :if={preview_href(svc)}
                    href={preview_href(svc)}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="inline-flex shrink-0 items-center justify-center gap-1.5 rounded-lg border border-border bg-surface px-2.5 py-1.5 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
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
            message="Start a service from this lane so owners can inspect output before approvals."
          >
            <:icon_slot>
              <.icon name="hero-bolt-mini" class="h-5 w-5" />
            </:icon_slot>
          </.empty_state>
        </section>

        <div class="grid gap-5">
          <section class="overflow-hidden rounded-lg border border-border bg-panel">
            <div class="border-b border-border px-4 py-3">
              <p class="text-sm font-590 text-text-primary">Environment guardrails</p>
              <p class="mt-1 text-xs leading-5 text-text-tertiary">
                Leases and probes show whether shared environments are safe to use.
              </p>
            </div>

            <div class="grid divide-y divide-border lg:grid-cols-2 lg:divide-x lg:divide-y-0">
              <div>
                <div class="border-b border-border px-4 py-3 text-xs font-590 text-text-secondary">
                  Leases
                </div>
                <div :if={!Enum.empty?(@leases)} class="divide-y divide-border">
                  <div :for={lease <- @leases} class="p-4">
                    <div class="flex items-center justify-between gap-3">
                      <p class="text-sm font-590 text-text-primary">{status_label(lease.status)}</p>
                      <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{lease_status_badge_class(lease.status)}"}>
                        {status_label(lease.cleanup_status || lease.lease_policy || "lease")}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-text-tertiary">{lease_detail(lease)}</p>
                  </div>
                </div>
                <p :if={Enum.empty?(@leases)} class="px-4 py-6 text-sm text-text-tertiary">
                  No environment leases.
                </p>
              </div>

              <div>
                <div class="border-b border-border px-4 py-3 text-xs font-590 text-text-secondary lg:border-l-0">
                  Probes
                </div>
                <div :if={!Enum.empty?(@probes)} class="divide-y divide-border">
                  <div :for={probe <- @probes} class="p-4">
                    <div class="flex items-center justify-between gap-3">
                      <p class="text-sm font-590 text-text-primary">{probe.probe_type}</p>
                      <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{probe_status_badge_class(probe.status)}"}>
                        {status_label(probe.status)}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-text-tertiary">{probe_detail(probe)}</p>
                  </div>
                </div>
                <p :if={Enum.empty?(@probes)} class="px-4 py-6 text-sm text-text-tertiary">
                  No environment probes.
                </p>
              </div>
            </div>
          </section>

          <section class="overflow-hidden rounded-lg border border-border bg-panel">
            <div class="border-b border-border px-4 py-3">
              <p class="text-sm font-590 text-text-primary">Operations log</p>
              <p class="mt-1 text-xs leading-5 text-text-tertiary">
                Recent workspace commands, exits, and excerpts for debugging launches.
              </p>
            </div>

            <div :if={!Enum.empty?(@operations)} class="divide-y divide-border">
              <div :for={op <- @operations} class="p-4">
                <div class="flex min-w-0 items-start justify-between gap-3">
                  <div class="min-w-0">
                    <div class="flex flex-wrap items-center gap-2">
                      <h3 class="truncate text-sm font-590 text-text-primary">{op.phase}</h3>
                      <span class={"rounded-full border px-2 py-0.5 text-[11px] font-510 #{operation_status_badge_class(op.status)}"}>
                        {status_label(op.status)}
                      </span>
                    </div>

                    <p :if={op.command} class="mt-1 truncate font-mono text-xs text-text-tertiary">
                      {op.command}
                    </p>
                    <p
                      :if={operation_excerpt(op)}
                      class="mt-2 line-clamp-2 text-xs leading-5 text-text-quaternary"
                    >
                      {operation_excerpt(op)}
                    </p>
                  </div>

                  <span
                    :if={op.exit_code}
                    class="shrink-0 rounded-full border border-border bg-surface px-2 py-1 font-mono text-xs text-text-tertiary"
                  >
                    exit {op.exit_code}
                  </span>
                </div>
              </div>
            </div>

            <.empty_state
              :if={Enum.empty?(@operations)}
              title="No operations recorded"
              message="Workspace launches, installs, and cleanup commands will appear here."
            >
              <:icon_slot>
                <.icon name="hero-clipboard-document-list-mini" class="h-5 w-5" />
              </:icon_slot>
            </.empty_state>
          </section>
        </div>
      </div>
    </.page>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :tone, :atom, default: :neutral

  def runtime_metric(assigns) do
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

  defp runtime_command(workspace, runtime_services, operations, leases, probes) do
    metrics = runtime_metrics(runtime_services, operations, leases, probes)
    tone = runtime_tone(workspace, metrics)

    %{
      tone: tone,
      badge: runtime_badge(tone),
      heading: runtime_heading(tone),
      detail: runtime_detail(tone, metrics),
      metrics: [
        %{
          label: "Services",
          value: metrics.running_services,
          tone: count_tone(metrics.running_services, :ok)
        },
        %{
          label: "Previews",
          value: metrics.previewable_services,
          tone: count_tone(metrics.previewable_services, :ok)
        },
        %{
          label: "Unhealthy",
          value: metrics.unhealthy_services,
          tone: count_tone(metrics.unhealthy_services, :critical)
        },
        %{
          label: "Leases",
          value: metrics.active_leases,
          tone: count_tone(metrics.active_leases, :ok)
        },
        %{
          label: "Probe fails",
          value: metrics.failed_probes,
          tone: count_tone(metrics.failed_probes, :critical)
        },
        %{
          label: "Op fails",
          value: metrics.failed_operations,
          tone: count_tone(metrics.failed_operations, :critical)
        }
      ]
    }
  end

  defp runtime_metrics(runtime_services, operations, leases, probes) do
    running_services = Enum.filter(runtime_services, &(&1.status == "running"))

    %{
      running_services: length(running_services),
      previewable_services: Enum.count(running_services, &preview_href/1),
      unhealthy_services: Enum.count(runtime_services, &unhealthy_service?/1),
      active_leases: Enum.count(leases, &(&1.status == "active")),
      failed_probes: Enum.count(probes, &(&1.status in @bad_probe_statuses)),
      failed_operations: Enum.count(operations, &(&1.status in ["failed", "error"]))
    }
  end

  defp runtime_tone(_workspace, %{
         unhealthy_services: services,
         failed_probes: probes,
         failed_operations: ops
       })
       when services > 0 or probes > 0 or ops > 0,
       do: :critical

  defp runtime_tone(%{status: status}, _metrics) when status in ["closed", "cleaned_up"],
    do: :idle

  defp runtime_tone(_workspace, %{running_services: 0}), do: :warning
  defp runtime_tone(_workspace, _metrics), do: :healthy

  defp runtime_badge(:critical), do: "Repair"
  defp runtime_badge(:warning), do: "No service"
  defp runtime_badge(:healthy), do: "Running"
  defp runtime_badge(:idle), do: "Closed"

  defp runtime_heading(:critical), do: "This lane needs repair before review"
  defp runtime_heading(:warning), do: "Start a service before asking for owner inspection"
  defp runtime_heading(:healthy), do: "This lane is ready for preview and review"
  defp runtime_heading(:idle), do: "This lane is closed"

  defp runtime_detail(:critical, metrics) do
    "#{metrics.unhealthy_services} unhealthy service(s), #{metrics.failed_probes} failed probe(s), and #{metrics.failed_operations} failed operation(s) need attention."
  end

  defp runtime_detail(:warning, _metrics) do
    "No running runtime service is attached, so owners cannot inspect a preview from this lane yet."
  end

  defp runtime_detail(:healthy, metrics) do
    "#{metrics.running_services} running service(s), #{metrics.previewable_services} preview target(s), and #{metrics.active_leases} active lease(s) are available."
  end

  defp runtime_detail(:idle, _metrics) do
    "The execution workspace is no longer open. Use operations history for traceability."
  end

  defp command_badge_class(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp command_badge_class(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp command_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp command_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp command_action_class(:critical),
    do: "border-red-500/25 bg-red-500/10 text-red-100 hover:bg-red-500/15"

  defp command_action_class(:warning),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-100 hover:bg-amber-500/15"

  defp command_action_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-100 hover:bg-emerald-500/15"

  defp command_action_class(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp execution_status_badge_class(status) when status in ["open", "running", "active"],
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp execution_status_badge_class(status) when status in ["failed", "error"],
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp execution_status_badge_class(_status),
    do: "border-border bg-surface text-text-tertiary"

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

  defp lease_status_badge_class("active"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp lease_status_badge_class("expired"), do: "border-red-500/25 bg-red-500/10 text-red-300"
  defp lease_status_badge_class(_status), do: "border-border bg-surface text-text-tertiary"

  defp probe_status_badge_class(status) when status in @bad_probe_statuses,
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp probe_status_badge_class("passing"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp probe_status_badge_class("healthy"),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp probe_status_badge_class(_status), do: "border-border bg-surface text-text-tertiary"

  defp operation_status_badge_class(status) when status in ["failed", "error"],
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp operation_status_badge_class(status) when status in ["ok", "done", "completed", "success"],
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp operation_status_badge_class(_status),
    do: "border-border bg-surface text-text-tertiary"

  defp metric_text(:critical), do: "text-red-300"
  defp metric_text(:warning), do: "text-amber-300"
  defp metric_text(:ok), do: "text-emerald-300"
  defp metric_text(_), do: "text-text-primary"

  defp count_tone(0, _tone), do: :neutral
  defp count_tone(_count, tone), do: tone

  defp unhealthy_service?(service) do
    service.status in ["failed", "error"] or service.health_status in @bad_service_health
  end

  defp preview_href(%{url: url}) when is_binary(url) and url != "", do: url

  defp preview_href(%{status: "running", port: port, id: id}) when is_integer(port),
    do: "/preview/#{id}"

  defp preview_href(_service), do: nil

  defp connection_string(%{url: url}) when is_binary(url) and url != "", do: url
  defp connection_string(%{port: port}) when is_integer(port), do: "localhost:#{port}"
  defp connection_string(_service), do: nil

  defp execution_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp execution_location(%{base_ref: base_ref}) when is_binary(base_ref) and base_ref != "",
    do: base_ref

  defp execution_location(_workspace), do: "No execution path recorded"

  defp service_detail(service) do
    [
      service.url,
      service_port(service),
      service.provider,
      service.cwd
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No preview endpoint or provider metadata recorded"
      parts -> Enum.join(parts, " | ")
    end
  end

  defp service_port(%{port: nil}), do: nil
  defp service_port(%{port: port}), do: ":#{port}"

  defp lease_detail(lease) do
    [
      expires_label(lease.expires_at),
      lease.failure_reason,
      lease.provider
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No lease timing or provider metadata recorded"
      parts -> Enum.join(parts, " | ")
    end
  end

  defp probe_detail(probe) do
    [
      checked_label(probe.last_checked_at),
      next_check_label(probe.next_check_at),
      result_summary(probe.result)
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No probe timing or result metadata recorded"
      parts -> Enum.join(parts, " | ")
    end
  end

  defp operation_excerpt(%{stderr_excerpt: excerpt}) when is_binary(excerpt) and excerpt != "",
    do: excerpt

  defp operation_excerpt(%{stdout_excerpt: excerpt}) when is_binary(excerpt) and excerpt != "",
    do: excerpt

  defp operation_excerpt(_operation), do: nil

  defp expires_label(nil), do: nil
  defp expires_label(datetime), do: "expires #{format_datetime(datetime)}"

  defp checked_label(nil), do: nil
  defp checked_label(datetime), do: "checked #{format_datetime(datetime)}"

  defp next_check_label(nil), do: nil
  defp next_check_label(datetime), do: "next #{format_datetime(datetime)}"

  defp result_summary(result) when map_size(result) == 0, do: nil

  defp result_summary(result) when is_map(result) do
    result
    |> Enum.take(2)
    |> Enum.map(fn {key, value} -> "#{key}: #{inspect(value)}" end)
    |> Enum.join(", ")
  end

  defp result_summary(_result), do: nil

  defp format_datetime(datetime), do: Calendar.strftime(datetime, "%Y-%m-%d %H:%M")

  defp blank?(value), do: is_nil(value) or value == ""

  defp status_label(nil), do: "Unknown"

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
