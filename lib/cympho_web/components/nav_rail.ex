defmodule CymphoWeb.Components.NavRail do
  @moduledoc """
  The Cympho sidebar.

  Sections:
    1. Primary action  — New issue
    2. Top-level pins  — Dashboard, Board, Inbox (with unread badge)
    3. WORK            — Issues, Goals, Routines
    4. PROJECTS        — color dot · name · open-issue count, capped at 6
    5. AGENTS          — role icon · name · live status dot, capped at 8

    The "More" section (Org / Approvals / Costs / Activity / Workspaces /
    Plugins / Skills / Adapters / Tool traces / Settings) lives in the
    user menu at the bottom of the sidebar — see `UserMenu`.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  @projects_visible 6
  @agents_visible 8

  attr :current_path, :string, required: true
  attr :projects, :list, default: []
  attr :agents, :list, default: []
  attr :inbox_count, :integer, default: 0
  attr :rest, :global

  def nav_rail(assigns) do
    {visible_projects, hidden_projects_count} =
      take_with_overflow(assigns.projects, @projects_visible)

    {visible_agents, hidden_agents_count} = take_with_overflow(assigns.agents, @agents_visible)

    assigns =
      assigns
      |> assign(:visible_projects, visible_projects)
      |> assign(:hidden_projects_count, hidden_projects_count)
      |> assign(:visible_agents, visible_agents)
      |> assign(:hidden_agents_count, hidden_agents_count)

    ~H"""
    <nav class="flex-1 overflow-y-auto py-2.5 px-2 space-y-0.5" {@rest}>
      <.primary_action />

      <div class="h-1.5"></div>

      <.nav_link
        to={~p"/dashboard"}
        label="Dashboard"
        icon="hero-squares-2x2-mini"
        current_path={@current_path}
      />
      <.nav_link
        to={~p"/kanban"}
        label="Board"
        icon="hero-view-columns-mini"
        current_path={@current_path}
      />
      <.nav_link
        to={~p"/inbox"}
        label="Inbox"
        icon="hero-inbox-mini"
        current_path={@current_path}
        badge={@inbox_count}
      />
      <.nav_link
        to={~p"/operations"}
        label="Operations"
        icon="hero-command-line-mini"
        current_path={@current_path}
      />

      <.section_header label="Work" />
      <.nav_link
        to={~p"/issues"}
        label="Issues"
        icon="hero-clipboard-document-list-mini"
        current_path={@current_path}
      />
      <.nav_link to={~p"/goals"} label="Goals" icon="hero-flag-mini" current_path={@current_path} />
      <.nav_link
        to={~p"/routines"}
        label="Routines"
        icon="hero-arrow-path-rounded-square-mini"
        current_path={@current_path}
      />

      <.section_header label="Projects" action_to={~p"/projects/new"} action_label="New project" />
      <p
        :if={@visible_projects == []}
        class="px-3 py-1.5 text-xs text-text-quaternary italic"
      >
        No projects yet.
      </p>
      <.project_row
        :for={project <- @visible_projects}
        project={project}
        current_path={@current_path}
      />
      <.link
        :if={@hidden_projects_count > 0}
        navigate={~p"/projects"}
        class="block px-3 py-1.5 text-[12px] text-text-quaternary hover:text-text-secondary"
      >
        Show {@hidden_projects_count} more…
      </.link>

      <.section_header label="Agents" action_to={~p"/agents/new"} action_label="New agent" />
      <p
        :if={@visible_agents == []}
        class="px-3 py-1.5 text-xs text-text-quaternary italic"
      >
        No agents yet.
      </p>
      <.agent_row
        :for={agent <- @visible_agents}
        agent={agent}
        current_path={@current_path}
        leadership?={leadership?(agent)}
      />
      <.link
        :if={@hidden_agents_count > 0}
        navigate={~p"/agents"}
        class="block px-3 py-1.5 text-[12px] text-text-quaternary hover:text-text-secondary"
      >
        Show {@hidden_agents_count} more…
      </.link>

      <div class="h-3"></div>
    </nav>
    """
  end

  ## ── Sections ───────────────────────────────────────────────────

  defp primary_action(assigns) do
    ~H"""
    <button
      type="button"
      data-quick-create-trigger
      class={[
        "w-full flex items-center gap-2.5 px-3 py-2 rounded-md",
        "text-[13px] font-510 text-text-primary",
        "bg-brand/15 hover:bg-brand/25 border border-brand/30",
        "transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
      ]}
    >
      <span class="hero-pencil-square-mini w-4 h-4 text-brand"></span>
      <span class="flex-1 text-left">New issue</span>
      <kbd class="kbd">C</kbd>
    </button>
    """
  end

  attr :label, :string, required: true
  attr :action_to, :string, default: nil
  attr :action_label, :string, default: nil

  defp section_header(assigns) do
    ~H"""
    <div class="flex items-center justify-between px-3 pt-3 pb-1">
      <span class="text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
        {@label}
      </span>
      <.link
        :if={@action_to}
        navigate={@action_to}
        aria-label={@action_label}
        title={@action_label}
        class="p-1 -mr-1 rounded text-text-quaternary hover:text-text-primary hover:bg-surface-hover transition-colors"
      >
        <span class="hero-plus-mini w-3.5 h-3.5"></span>
      </.link>
    </div>
    """
  end

  ## ── Top-level link ─────────────────────────────────────────────

  attr :to, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0

  defp nav_link(assigns) do
    active? = active?(assigns.to, assigns.current_path)
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link
      navigate={@to}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-md text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
      data-nav-path={@to}
      data-active={if @active?, do: "true", else: "false"}
      aria-current={if @active?, do: "page", else: nil}
    >
      <span class={[@icon, "w-4 h-4 shrink-0"]}></span>
      <span class="flex-1 truncate">{@label}</span>
      <span
        :if={@badge && @badge > 0}
        class="inline-flex items-center justify-center min-w-[18px] h-[18px] px-1 rounded-full bg-red-500/90 text-white text-[10px] font-590"
      >
        {@badge}
      </span>
    </.link>
    """
  end

  ## ── Project row ────────────────────────────────────────────────

  attr :project, :map, required: true
  attr :current_path, :string, required: true

  defp project_row(assigns) do
    href = ~p"/projects/#{assigns.project.id}"
    assigns = assign(assigns, :href, href)
    assigns = assign(assigns, :active?, active?(href, assigns.current_path))

    ~H"""
    <.link
      navigate={@href}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-md text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
      data-nav-path={@href}
      data-active={if @active?, do: "true", else: "false"}
      aria-current={if @active?, do: "page", else: nil}
    >
      <span
        class="h-2.5 w-2.5 rounded-full shrink-0 border border-white/10"
        style={"background-color: #{@project.color || "#6b7280"}"}
        aria-hidden="true"
      >
      </span>
      <span class="flex-1 truncate">{@project.name}</span>
      <span
        :if={(@project[:open_count] || 0) > 0}
        class="text-[11px] text-text-quaternary tabular-nums"
      >
        {@project.open_count}
      </span>
    </.link>
    """
  end

  ## ── Agent row ──────────────────────────────────────────────────

  attr :agent, :map, required: true
  attr :current_path, :string, required: true
  attr :leadership?, :boolean, default: false

  defp agent_row(assigns) do
    href = ~p"/agents/#{assigns.agent.id}"
    assigns = assign(assigns, :href, href)
    assigns = assign(assigns, :active?, active?(href, assigns.current_path))

    ~H"""
    <.link
      navigate={@href}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-md text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
      ]}
      data-nav-path={@href}
      data-active={if @active?, do: "true", else: "false"}
      aria-current={if @active?, do: "page", else: nil}
    >
      <span class={[role_icon(@agent.role), "w-4 h-4 shrink-0", role_icon_color(@agent.role)]}></span>
      <span class="flex-1 truncate">{@agent.name}</span>
      <span
        class="h-1.5 w-1.5 rounded-full shrink-0"
        title={status_label(@agent.status)}
        style={"background-color: #{status_color(@agent.status)}"}
      >
      </span>
    </.link>
    """
  end

  ## ── Helpers ────────────────────────────────────────────────────

  defp leadership?(%{role: r}) when r in [:ceo, :cto], do: true
  defp leadership?(_), do: false

  defp take_with_overflow(list, n) when is_list(list) do
    case length(list) do
      total when total <= n -> {list, 0}
      total -> {Enum.take(list, n), total - n}
    end
  end

  defp active?("/", current_path), do: current_path == "/"

  defp active?(path, current_path),
    do: current_path == path or String.starts_with?(current_path || "", path <> "/")

  defp role_icon(:ceo), do: "hero-sparkles-mini"
  defp role_icon(:cto), do: "hero-cpu-chip-mini"
  defp role_icon(:engineer), do: "hero-wrench-screwdriver-mini"
  defp role_icon(:product_manager), do: "hero-clipboard-document-check-mini"
  defp role_icon(:designer), do: "hero-paint-brush-mini"
  defp role_icon(_), do: "hero-user-mini"

  defp role_icon_color(:ceo), do: "text-brand"
  defp role_icon_color(:cto), do: "text-sky-300"
  defp role_icon_color(:engineer), do: "text-emerald-300"
  defp role_icon_color(:product_manager), do: "text-amber-300"
  defp role_icon_color(:designer), do: "text-fuchsia-300"
  defp role_icon_color(_), do: "text-text-quaternary"

  defp status_color(:running), do: "#10b981"
  defp status_color(:active), do: "#10b981"
  defp status_color(:sleeping), do: "#f59e0b"
  defp status_color(:paused), do: "#f59e0b"
  defp status_color(:pending_approval), do: "#a855f7"
  defp status_color(:error), do: "#ef4444"
  defp status_color(:offline), do: "#3b3d44"
  defp status_color(:terminated), do: "#3b3d44"
  defp status_color(_), do: "#6b7280"

  defp status_label(:running), do: "Running"
  defp status_label(:active), do: "Active"
  defp status_label(:sleeping), do: "Sleeping"
  defp status_label(:paused), do: "Paused"
  defp status_label(:pending_approval), do: "Pending approval"
  defp status_label(:error), do: "Error"
  defp status_label(:offline), do: "Offline"
  defp status_label(:idle), do: "Idle"
  defp status_label(:terminated), do: "Terminated"
  defp status_label(other), do: to_string(other)
end
