defmodule CymphoWeb.WorkspaceLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Projects
  alias Cympho.Workspaces

  @impl true
  def mount(_params, _session, socket) do
    company_id = current_company_id(socket)
    workspace_health = Workspaces.health_summary(company_id)

    {:ok,
     socket
     |> assign(:workspace_health, workspace_health)
     |> assign(:workspace_command, workspace_command(workspace_health))
     |> assign(:workspace_inventory, Workspaces.workspace_inventory(company_id))
     |> assign(:project_names, project_names(company_id))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Work files")
  end

  defp apply_action(socket, nil, params), do: apply_action(socket, :index, params)

  defp current_company_id(socket) do
    case socket.assigns do
      %{current_company: %{id: id}} -> id
      %{current_user: %{company_id: id}} -> id
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.page_frame page="workfiles" title="Work files" data-ui-complex-page>
      <.flash_line flash={@flash} />

      <.band_card id="workfiles-t" title="Work folders" section_id="workspace-list">
        <:header_end>
          <span class="wf-end">
            <span :if={@workspace_command} class="st-w wf-st">
              <.status_word
                kind={level_kind(@workspace_command.tone)}
                word={@workspace_command.badge}
              />
            </span>
            <.text_link navigate="/operations#runtime-launch-checklist">Runtime checklist</.text_link>
          </span>
        </:header_end>

        <div :if={@workspace_command} class="gl-sec" data-testid="workspace-command">
          <div data-testid="workspace-health">
            <p class="gl-big">{@workspace_command.heading}</p>
            <p class="gl-sub">{@workspace_command.detail}</p>
          </div>
          <ul :if={@workspace_health.recommendations != []} class="wf-recs">
            <li :for={rec <- @workspace_health.recommendations}>
              <.status_glyph kind={level_kind(rec.severity)} />
              <span><b>{rec.label}</b><span aria-hidden="true"> · </span>{rec.detail}</span>
            </li>
          </ul>
        </div>

        <ul :if={@workspace_inventory != []} class="rows" data-testid="workspace-list">
          <.list_row
            :for={item <- @workspace_inventory}
            id={"workspace-#{item.workspace.id}"}
            title={item.workspace.name}
            navigate={~p"/workspaces/#{item.workspace.id}"}
            icon="i-term"
            kind={if item.level == :critical, do: :problem, else: :neutral}
            status={{level_kind(item.level), item.label}}
          >
            <:meta>
              <.meta_parts items={[
                {@project_names[item.workspace.project_id], false},
                {workspace_ref(item.workspace), true},
                {workspace_location(item.workspace), true},
                {CymphoWeb.AgentLive.Parts.stamp(item.workspace.updated_at), true}
              ]} />
            </:meta>
            <:trail :if={item.workspace.is_primary}><span class="tag">Primary</span></:trail>
          </.list_row>
        </ul>

        <.quiet_empty :if={@workspace_inventory == []} title="No work folders yet">
          Add a folder or repository to a project so agents have somewhere to run.
          <:action>
            <.pill navigate={~p"/projects/new"}>New project</.pill>
          </:action>
        </.quiet_empty>
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

  # Health levels as status shapes (v7 §1.5): repair is a stop, inspect/watch a wait.
  defp level_kind(:critical), do: :stopped
  defp level_kind(:warning), do: :waiting
  defp level_kind(:healthy), do: :done
  defp level_kind(_level), do: :idle

  # The command line shows only once a folder exists (the empty list says the rest).
  defp workspace_command(%{metrics: %{total_project_workspaces: 0}}), do: nil

  defp workspace_command(%{level: level, summary: summary}) do
    %{
      tone: level,
      badge: workspace_command_badge(level),
      heading: workspace_command_heading(level),
      detail: workspace_command_detail(level, summary)
    }
  end

  defp project_names(nil), do: %{}

  defp project_names(company_id) do
    company_id
    |> Projects.list_projects_by_company()
    |> Map.new(&{&1.id, &1.name})
  end

  defp workspace_command_badge(:critical), do: "Needs attention"
  defp workspace_command_badge(:warning), do: "Watch"
  defp workspace_command_badge(:healthy), do: "Healthy"

  defp workspace_command_heading(:critical), do: "Repair runtime before handing work to agents"

  defp workspace_command_heading(:warning),
    do: "Inspect workspace runtime before relying on previews"

  defp workspace_command_heading(:healthy),
    do: "Workspace infrastructure is ready for autonomous runs"

  defp workspace_command_detail(:healthy, _summary) do
    "Agents have execution lanes and inspectable runtime services. Keep leases and probes visible while the CEO delegates work."
  end

  defp workspace_command_detail(_level, summary), do: summary

  defp workspace_location(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd

  defp workspace_location(%{repo_url: repo_url}) when is_binary(repo_url) and repo_url != "",
    do: repo_url

  defp workspace_location(_workspace), do: "No path or repository configured"

  defp workspace_ref(%{default_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(%{repo_ref: ref}) when is_binary(ref) and ref != "", do: ref
  defp workspace_ref(_workspace), do: nil
end
