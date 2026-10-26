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
       |> assign(:page_title, workspace.name)
       |> assign(:workspace, workspace)
       |> assign(:parent, parent_folder(workspace))
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

  # The breadcrumb's parent is the project folder this run belongs to, by name (v7 O5).
  defp parent_folder(%{project_workspace_id: nil}), do: {~p"/workspaces", "Work files"}

  defp parent_folder(%{company_id: company_id, project_workspace_id: id}) do
    case Workspaces.get_company_project_workspace(company_id, id) do
      {:ok, folder} -> {~p"/workspaces/#{folder.id}", folder.name}
      {:error, _} -> {~p"/workspaces", "Work files"}
    end
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame
      page="exec"
      kind={:deep}
      parent={@parent}
      current={@workspace.name}
      tray_class="split"
      data-ui-complex-page
    >
      <:head>
        <section class="head" aria-labelledby="ex-h">
          <h1 class="h1 big" id="ex-h">{@workspace.name}</h1>
          <p class="sub">
            Run folder<span :if={@workspace.mode}> · {@workspace.mode}</span>
            <span :if={@workspace.opened_at}>
              <span aria-hidden="true"> · </span>opened
              <span class="mono">{CymphoWeb.AgentLive.Parts.stamp(@workspace.opened_at)}</span>
            </span>
          </p>
          <div class="chips">
            <span class="chip">
              <.status_word kind={level_kind(@runtime_command.tone)} word={@runtime_command.badge} />
            </span>
          </div>
          <.flash_line flash={@flash} />
        </section>
      </:head>

      <.band_card id="ex-cmd-t" title="Health" data-testid="execution-workspace-command">
        <:header_end>
          <.text_link navigate="/operations#runtime-launch-checklist">Runtime checklist</.text_link>
        </:header_end>
        <div class="gl-sec">
          <p class="gl-big">{@runtime_command.heading}</p>
          <p class="gl-sub">{@runtime_command.detail}</p>
        </div>
      </.band_card>

      <.band_card id="ex-svc-t" title="Services">
        <ul :if={@runtime_services != []} class="rows">
          <.list_row
            :for={svc <- @runtime_services}
            id={"svc-#{svc.id}"}
            title={svc.service_name}
            status={service_status(svc)}
          >
            <:trail :if={service_lifecycle(svc)}>
              <span class="tag">{service_lifecycle(svc)}</span>
            </:trail>
            <:meta>
              <span class="wf-loc">{service_detail(svc)}</span><span :if={svc.command}><span aria-hidden="true"> · </span><span class="mono wf-loc">{svc.command}</span></span>
            </:meta>
            <:actions :if={preview_href(svc) || connection_string(svc)}>
              <span id={"exec-svc-conn-#{svc.id}"} class="wf-acts" phx-hook="CopyToClipboard">
                <button
                  :if={connection_string(svc)}
                  type="button"
                  class="pl"
                  data-copy-text={connection_string(svc)}
                  data-copy-success-label="Copied"
                >
                  Copy
                </button>
                <a
                  :if={preview_href(svc)}
                  class="pl"
                  href={preview_href(svc)}
                  target="_blank"
                  rel="noopener noreferrer"
                >
                  Preview <.r3_icon name="i-external" class="ico s14" />
                </a>
              </span>
            </:actions>
          </.list_row>
        </ul>
        <%!-- Why a service matters is the Health band's line above; this one only says none runs. --%>
        <.quiet_empty :if={@runtime_services == []} title="No services running">
          <:action>
            <.pill navigate="/operations#runtime-launch-checklist">Start service</.pill>
          </:action>
        </.quiet_empty>
      </.band_card>

      <.band_card id="ex-guard-t" title="Environment guardrails">
        <p class="gh">Leases <span class="mono">{length(@leases)}</span></p>
        <ul :if={@leases != []} class="rows">
          <.list_row
            :for={lease <- @leases}
            id={"lease-#{lease.id}"}
            title={status_label(lease.cleanup_status || lease.lease_policy || "lease")}
            status={lease_status(lease.status)}
          >
            <:meta>{lease_detail(lease)}</:meta>
          </.list_row>
        </ul>
        <p :if={@leases == []} class="gl-sub ex-none">No environment leases.</p>
        <p class="gh">Probes <span class="mono">{length(@probes)}</span></p>
        <ul :if={@probes != []} class="rows">
          <.list_row
            :for={probe <- @probes}
            id={"probe-#{probe.id}"}
            title={probe.probe_type}
            status={probe_status(probe.status)}
          >
            <:meta>{probe_detail(probe)}</:meta>
          </.list_row>
        </ul>
        <p :if={@probes == []} class="gl-sub ex-none">No environment probes.</p>
      </.band_card>

      <.band_card id="ex-ops-t" title="Operations log">
        <ul :if={@operations != []} class="rows">
          <.list_row
            :for={op <- @operations}
            id={"op-#{op.id}"}
            title={op.phase}
            icon="i-term"
            kind={if op.status in ["failed", "error"], do: :problem, else: :neutral}
            status={operation_status(op.status)}
          >
            <:meta>
              <span :if={op.command} class="mono wf-loc">{op.command}</span><span :if={
                op.command && op.exit_code
              }><span aria-hidden="true"> · </span></span><span
                :if={op.exit_code}
                class="mono"
              >exit {op.exit_code}</span>
            </:meta>
            <:below :if={operation_excerpt(op)}>
              <p class="ex-out mono">{operation_excerpt(op)}</p>
            </:below>
          </.list_row>
        </ul>
        <.quiet_empty :if={@operations == []} title="No operations recorded">
          Launches, installs and cleanup commands for this run appear here.
        </.quiet_empty>
      </.band_card>

      <.band_card id="ex-folder-t" title="This run's folder" class="aside">
        <.kv_list>
          <:item :if={@workspace.branch_name} term="Branch">
            <span class="mono wf-loc">{@workspace.branch_name}</span>
          </:item>
          <:item :if={@workspace.base_ref} term="Base ref">
            <span class="mono">{@workspace.base_ref}</span>
          </:item>
          <:item term="Status">{status_label(@workspace.status)}</:item>
          <:item :if={@workspace.opened_at} term="Opened">
            {Calendar.strftime(@workspace.opened_at, "%a %-d %b")}
            <span class="mono">{Calendar.strftime(@workspace.opened_at, "%H:%M")}</span>
          </:item>
          <:item :if={@workspace.closed_at} term="Closed">
            {Calendar.strftime(@workspace.closed_at, "%a %-d %b")}
            <span class="mono">{Calendar.strftime(@workspace.closed_at, "%H:%M")}</span>
          </:item>
          <:item term="Folder">
            <span class="mono wf-loc">{execution_location(@workspace)}</span>
          </:item>
        </.kv_list>
        <div
          :if={present?(@workspace.cwd)}
          id="exec-folder-copy"
          class="ex-copy"
          phx-hook="CopyToClipboard"
        >
          <.chip data-copy-text={@workspace.cwd} data-copy-success-label="Copied">Copy path</.chip>
        </div>
      </.band_card>
    </.page_frame>
    """
  end

  defp level_kind(:critical), do: :stopped
  defp level_kind(:warning), do: :waiting
  defp level_kind(:healthy), do: :done
  defp level_kind(_tone), do: :idle

  # A bad health report is the row's word; the lifecycle it came with stays beside it
  # (a stopped service keeps its last health, so the word alone would hide the stop).
  defp service_status(service) do
    cond do
      service.health_status in @bad_service_health ->
        {:stopped, status_label(service.health_status)}

      service.status in ["failed", "error"] ->
        {:stopped, status_label(service.status)}

      service.status == "running" ->
        {:done, "Running"}

      true ->
        {:idle, status_label(service.status)}
    end
  end

  defp service_lifecycle(service) do
    if service.health_status in @bad_service_health, do: status_label(service.status)
  end

  defp lease_status("active"), do: {:done, "Active"}
  defp lease_status("expired"), do: {:stopped, "Expired"}
  defp lease_status(status), do: {:idle, status_label(status)}

  defp probe_status(status) when status in @bad_probe_statuses,
    do: {:stopped, status_label(status)}

  defp probe_status(status) when status in ["passing", "healthy"],
    do: {:done, status_label(status)}

  defp probe_status(status), do: {:idle, status_label(status)}

  defp operation_status(status) when status in ["failed", "error"],
    do: {:stopped, status_label(status)}

  defp operation_status(status) when status in ["ok", "done", "completed", "success"],
    do: {:done, "Finished"}

  defp operation_status(status), do: {:idle, status_label(status)}

  defp present?(value), do: is_binary(value) and value != ""

  defp runtime_command(workspace, runtime_services, operations, leases, probes) do
    metrics = runtime_metrics(runtime_services, operations, leases, probes)
    tone = runtime_tone(workspace, metrics)

    %{
      tone: tone,
      badge: runtime_badge(tone),
      heading: runtime_heading(tone),
      detail: runtime_detail(tone, metrics)
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

  defp unhealthy_service?(service) do
    service.status in ["failed", "error"] or service.health_status in @bad_service_health
  end

  defp preview_href(service),
    do: Cympho.Workspaces.PreviewUrl.generate_preview_url(service, "")

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
      # a bad report is already the row's status word
      if(service.health_status not in @bad_service_health, do: service.health_status),
      service.provider,
      service.cwd
    ]
    |> Enum.reject(&blank?/1)
    |> case do
      [] -> "No preview endpoint or provider metadata recorded"
      parts -> Enum.join(parts, " · ")
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
      parts -> Enum.join(parts, " · ")
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
      parts -> Enum.join(parts, " · ")
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
