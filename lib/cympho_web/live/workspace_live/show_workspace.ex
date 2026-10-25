defmodule CymphoWeb.WorkspaceLive.ShowWorkspace do
  use CymphoWeb, :live_view
  alias Cympho.Projects
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
       |> assign(:page_title, workspace.name)
       |> assign(:workspace, workspace)
       |> assign(:project, company_project(workspace))
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

  defp company_project(%{project_id: nil}), do: nil

  defp company_project(%{company_id: company_id, project_id: project_id}) do
    case Projects.get_company_project(company_id, project_id) do
      {:ok, project} -> project
      {:error, _} -> nil
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
      page="workfile"
      kind={:deep}
      parent={{~p"/workspaces", "Work files"}}
      current={@workspace.name}
      tray_class="split"
      data-ui-complex-page
    >
      <:head>
        <section class="head" aria-labelledby="wf-h">
          <h1 class="h1 big" id="wf-h">{@workspace.name}</h1>
          <p class="sub">
            {if @project, do: "Folder for #{@project.name}", else: "Folder with no project"}<span aria-hidden="true"> · </span>added
            <span class="mono">{CymphoWeb.AgentLive.Parts.stamp(@workspace.inserted_at)}</span>
          </p>
          <div id="workfile-chips" class="chips" phx-hook="CopyToClipboard">
            <span class="chip">
              <.status_word
                kind={level_kind(@workspace_command.tone)}
                word={@workspace_command.badge}
              />
            </span>
            <.chip
              :if={copy_path(@workspace)}
              data-copy-text={copy_path(@workspace)}
              data-copy-success-label="Copied"
            >
              Copy path
            </.chip>
          </div>
          <.flash_line flash={@flash} />
        </section>
      </:head>

      <.band_card id="wf-cmd-t" title="Health" data-testid="project-workspace-command">
        <:header_end :if={@workspace_command.action_path}>
          <.text_link navigate={@workspace_command.action_path}>
            {@workspace_command.action_label}
          </.text_link>
        </:header_end>
        <div class="gl-sec">
          <p class="gl-big">{@workspace_command.heading}</p>
          <p class="gl-sub">{@workspace_command.detail}</p>
        </div>
      </.band_card>

      <.band_card id="wf-runs-t" title="Runs in this folder">
        <:header_end :if={@execution_workspaces != []}>
          <span class="meta mono">{length(@execution_workspaces)}</span>
        </:header_end>
        <ul :if={@execution_workspaces != []} class="rows">
          <.list_row
            :for={ew <- @execution_workspaces}
            id={"exec-#{ew.id}"}
            title={ew.name}
            navigate={~p"/workspaces/#{@workspace.id}/exec/#{ew.id}"}
            status={exec_status(ew.status)}
          >
            <:meta>
              <.meta_parts items={[
                {ew.branch_name, true},
                {ew.mode, false},
                {execution_detail(ew), true}
              ]} />
            </:meta>
          </.list_row>
        </ul>
        <.quiet_empty :if={@execution_workspaces == []} title="No runs yet">
          Assign a task to an agent and its run folder opens here.
        </.quiet_empty>
      </.band_card>

      <.band_card id="wf-svc-t" title="Services">
        <ul :if={@runtime_services != []} class="rows">
          <.list_row
            :for={svc <- @runtime_services}
            id={"svc-#{svc.id}"}
            title={svc.service_name}
            status={service_status(svc)}
          >
            <:meta><span class="wf-loc">{service_detail(svc)}</span></:meta>
            <:actions :if={preview_href(svc) || connection_string(svc)}>
              <span id={"ws-svc-conn-#{svc.id}"} class="wf-acts" phx-hook="CopyToClipboard">
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
        <.quiet_empty :if={@runtime_services == []} title="No services running">
          Start a dev server in a run folder and it shows up here.
        </.quiet_empty>
      </.band_card>

      <.band_card id="wf-det-t" title="Details" class="aside">
        <.kv_list>
          <:item term="Project">{if @project, do: @project.name, else: "None"}</:item>
          <:item :if={present?(@workspace.repo_url)} term="Repository">
            <span class="mono wf-loc">{@workspace.repo_url}</span>
          </:item>
          <:item :if={workspace_ref(@workspace)} term="Ref">
            <span class="mono">{workspace_ref(@workspace)}</span>
          </:item>
          <:item :if={present?(@workspace.cwd)} term="Path">
            <span class="mono wf-loc">{@workspace.cwd}</span>
          </:item>
          <:item :if={@workspace.source_type} term="Source">{@workspace.source_type}</:item>
          <:item :if={@workspace.is_primary} term="Primary">Yes</:item>
        </.kv_list>
      </.band_card>
    </.page_frame>
    """
  end

  attr :items, :list, required: true, doc: "[{text, mono?}]; nil texts are skipped"

  # A row's meta line: its parts joined by a quiet separator, identifiers in mono.
  defp meta_parts(assigns) do
    assigns = assign(assigns, :items, Enum.reject(assigns.items, &is_nil(elem(&1, 0))))

    ~H"""
    <%= for {{text, mono?}, i} <- Enum.with_index(@items) do %>
      <span :if={i > 0} aria-hidden="true"> · </span><span class={[mono? && "mono", mono? && "wf-loc"]}>{text}</span>
    <% end %>
    """
  end

  defp level_kind(:critical), do: :stopped
  defp level_kind(:warning), do: :waiting
  defp level_kind(:healthy), do: :done
  defp level_kind(_tone), do: :idle

  # A run folder's state: only running and failed carry a colour (v7 §1.5).
  defp exec_status("running"), do: {:working, "Running"}

  defp exec_status(status) when status in ["failed", "error"],
    do: {:stopped, status_label(status)}

  defp exec_status(status), do: {:idle, status_label(status)}

  defp service_status(service) do
    cond do
      unhealthy_service?(service) ->
        {:stopped, status_label(service.health_status || service.status)}

      service.status == "running" ->
        {:done, "Running"}

      true ->
        {:idle, status_label(service.status)}
    end
  end

  defp copy_path(workspace) do
    cond do
      present?(workspace.cwd) -> workspace.cwd
      present?(workspace.repo_url) -> workspace.repo_url
      true -> nil
    end
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp workspace_command(_workspace, execution_workspaces, runtime_services) do
    metrics = workspace_metrics(execution_workspaces, runtime_services)
    tone = workspace_tone(metrics)

    %{
      tone: tone,
      badge: workspace_badge(tone),
      heading: workspace_heading(tone),
      detail: workspace_detail(tone, metrics),
      # An idle folder has nothing to inspect elsewhere; Back already leads to Work files.
      action_label: if(tone != :idle, do: "Open Health"),
      action_path: if(tone != :idle, do: "/operations")
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

  defp unhealthy_service?(service) do
    service.status in ["failed", "error"] or service.health_status in @bad_service_health
  end

  defp previewless_service?(service),
    do: not Cympho.Workspaces.PreviewUrl.previewable?(service)

  defp blank?(value), do: is_nil(value) or value == ""

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
      parts -> Enum.join(parts, " · ")
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
