defmodule CymphoWeb.Components.NavRail do
  @moduledoc """
  The Cympho sidebar.

  Sections:
    1. Primary action  — New issue
    2. Top-level pins  — Dashboard, Board, Inbox / Approvals (with badges)
    3. WORK            — Issues, Goals, Routines
    4. PROJECTS        — color dot · name · open-issue count, capped at 6
    5. AGENTS          — role icon · name · live status dot, capped at 8

    Settings (gear) pins to the top group. The "More" overflow (Org /
    Costs / Activity / Workspaces / Plugins / Skills / Tool
    traces) lives in the user menu at the bottom of the sidebar — see
    `UserMenu`.
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
  attr :approval_count, :integer, default: 0
  attr :current_company, :any, default: nil
  attr :runtime_controls_allowed, :boolean, default: false
  attr :rest, :global

  def nav_rail(assigns) do
    # Render every project/agent; rows past the initial cap are marked
    # `data-nav-overflow` and hidden until the "Show N more" button reveals them
    # (handled client-side in app.js — the nav lives in the conn-rendered root
    # layout, so collapse/expand state is JS + localStorage, not LiveView).
    assigns =
      assigns
      |> assign(:projects_visible, @projects_visible)
      |> assign(:agents_visible, @agents_visible)
      |> assign(:hidden_projects_count, max(0, length(assigns.projects) - @projects_visible))
      |> assign(:hidden_agents_count, max(0, length(assigns.agents) - @agents_visible))

    ~H"""
    <nav class="flex-1 overflow-y-auto py-2.5 px-2 space-y-0.5" data-ui-complex-page {@rest}>
      <.primary_action />

      <div class="h-1.5"></div>

      <.runtime_controls
        :if={@current_company && @runtime_controls_allowed}
        current_company={@current_company}
        current_path={@current_path}
      />

      <div :if={@current_company && @runtime_controls_allowed} class="h-1.5"></div>

      <.ui_mode_switcher />

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
        to={~p"/approvals?status=pending"}
        match="/approvals"
        label="Approvals"
        icon="hero-shield-check-mini"
        current_path={@current_path}
        badge={@approval_count}
        advanced_only
      />
      <.nav_link
        to={~p"/reviews"}
        label="Reviews"
        icon="hero-check-badge-mini"
        current_path={@current_path}
        advanced_only
      />
      <.nav_link
        to={~p"/operations"}
        label="Operations"
        icon="hero-command-line-mini"
        current_path={@current_path}
        advanced_only
      />
      <.nav_link
        to={~p"/settings/profile"}
        match="/settings"
        label="Settings"
        icon="hero-cog-6-tooth-mini"
        current_path={@current_path}
      />

      <.section_header label="Work" advanced_only />
      <.nav_link
        to={~p"/issues"}
        label="Issues"
        icon="hero-clipboard-document-list-mini"
        current_path={@current_path}
        advanced_only
      />
      <.nav_link
        to={~p"/launch-items"}
        label="Launch Tracker"
        icon="hero-sparkles-mini"
        current_path={@current_path}
        advanced_only
      />
      <.nav_link
        to={~p"/goals"}
        label="Goals"
        icon="hero-flag-mini"
        current_path={@current_path}
        advanced_only
      />
      <.nav_link
        to={~p"/routines"}
        label="Routines"
        icon="hero-arrow-path-rounded-square-mini"
        current_path={@current_path}
        advanced_only
      />

      <.nav_section
        key="projects"
        label="Projects"
        action_to={~p"/projects/new"}
        action_label="New project"
      >
        <p
          :if={@projects == []}
          class="px-3 py-1.5 text-xs text-text-quaternary italic"
        >
          No projects yet.
        </p>
        <.project_row
          :for={{project, idx} <- Enum.with_index(@projects)}
          project={project}
          overflow?={idx >= @projects_visible}
          current_path={@current_path}
        />
        <.show_more :if={@hidden_projects_count > 0} key="projects" count={@hidden_projects_count} />
      </.nav_section>

      <.nav_section
        key="agents"
        label="Agents"
        action_to={~p"/agents/new"}
        action_label="New agent"
      >
        <p
          :if={@agents == []}
          class="px-3 py-1.5 text-xs text-text-quaternary italic"
        >
          No agents yet.
        </p>
        <.agent_row
          :for={{agent, idx} <- Enum.with_index(@agents)}
          agent={agent}
          overflow?={idx >= @agents_visible}
          current_path={@current_path}
          leadership?={leadership?(agent)}
        />
        <.show_more :if={@hidden_agents_count > 0} key="agents" count={@hidden_agents_count} />
      </.nav_section>

      <div class="h-3"></div>
    </nav>
    """
  end

  attr :current_company, :any, required: true
  attr :current_path, :string, required: true

  defp runtime_controls(assigns) do
    ~H"""
    <div
      data-testid="runtime-controls"
      class="ui-advanced-only rounded-xl border border-border bg-surface-2/70 p-2 shadow-card"
    >
      <div class="mb-2 flex items-center justify-between gap-2 px-0.5">
        <span class="flex items-center gap-1.5 text-[11px] font-590 uppercase tracking-[0.08em] text-text-tertiary">
          <span class="hero-bolt-mini h-3.5 w-3.5 text-brand"></span> Runtime
        </span>
        <span class={[
          "rounded-full border px-2 py-0.5 text-[10px] font-590",
          if(company_paused?(@current_company),
            do: "border-amber-500/30 bg-amber-500/10 text-amber-300",
            else:
              if(company_low_power?(@current_company),
                do: "border-sky-500/30 bg-sky-500/10 text-sky-300",
                else: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
              )
          )
        ]}>
          {runtime_status_label(@current_company)}
        </span>
      </div>
      <div class={[
        "grid gap-1.5",
        if(company_paused?(@current_company), do: "grid-cols-2", else: "grid-cols-3")
      ]}>
        <.runtime_button
          :if={!company_paused?(@current_company) && !company_low_power?(@current_company)}
          action={~p"/runtime-control/low-power"}
          icon="hero-moon-mini"
          label="Low"
          tone="neutral"
          current_path={@current_path}
          confirm="Switch to low power? Only urgent work keeps running."
        />
        <.runtime_button
          :if={!company_paused?(@current_company) && company_low_power?(@current_company)}
          action={~p"/runtime-control/resume"}
          icon="hero-bolt-mini"
          label="Full"
          tone="neutral"
          current_path={@current_path}
        />
        <.runtime_button
          :if={!company_paused?(@current_company)}
          action={~p"/runtime-control/pause"}
          icon="hero-pause-mini"
          label="Pause"
          tone="neutral"
          current_path={@current_path}
          confirm="Pause your agents? Queued work is saved for later."
        />
        <.runtime_button
          :if={company_paused?(@current_company)}
          action={~p"/runtime-control/resume"}
          icon="hero-play-mini"
          label="Resume"
          tone="neutral"
          current_path={@current_path}
        />
        <.runtime_button
          action={~p"/runtime-control/stop"}
          icon="hero-stop-mini"
          label="Stop"
          tone="danger"
          current_path={@current_path}
          confirm="Stop your agents and clear the queue?"
        />
      </div>
    </div>
    """
  end

  attr :action, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :tone, :string, default: "neutral"
  attr :current_path, :string, required: true
  attr :confirm, :string, default: nil

  defp runtime_button(assigns) do
    ~H"""
    <form method="post" action={@action} class="min-w-0">
      <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
      <input type="hidden" name="return_to" value={@current_path} />
      <button
        type="submit"
        data-confirm={@confirm}
        class={[
          "inline-flex h-8 w-full items-center justify-center gap-1.5 rounded-lg border px-2 text-[12px] font-590 transition-colors",
          @tone == "danger" &&
            "border-red-500/25 bg-red-500/10 text-red-300 hover:bg-red-500/15 hover:text-red-200",
          @tone != "danger" &&
            "border-border bg-surface-1 text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        ]}
      >
        <span class={[@icon, "h-3.5 w-3.5 shrink-0"]}></span>
        <span class="truncate">{@label}</span>
      </button>
    </form>
    """
  end

  defp company_paused?(%{status: "paused"}), do: true
  defp company_paused?(_company), do: false

  defp company_low_power?(%{governance_config: %{"runtime_mode" => "low_power"}}), do: true
  defp company_low_power?(_company), do: false

  defp runtime_status_label(company) do
    cond do
      company_paused?(company) -> "Paused"
      company_low_power?(company) -> "Low"
      true -> "Live"
    end
  end

  defp ui_mode_switcher(assigns) do
    ~H"""
    <button
      type="button"
      data-ui-mode-toggle
      title="Toggle simple and advanced view with U"
      aria-label="Toggle simple and advanced view with U"
      aria-pressed="false"
      class="ui-mode-toggle flex w-full items-center gap-2.5 rounded-xl border border-border bg-surface-2/75 px-3 py-2 text-[13px] font-590 text-text-secondary shadow-card transition-colors hover:border-border-hover hover:bg-surface-hover hover:text-text-primary"
    >
      <span class="inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md border border-white/15 bg-white/10 text-white">
        <span data-ui-mode-icon class="hero-squares-2x2-mini h-3.5 w-3.5"></span>
      </span>
      <span class="min-w-0 flex-1 text-left">
        <span data-ui-mode-label>Simple</span>
      </span>
      <span class="hero-chevron-up-down-mini h-3.5 w-3.5 shrink-0 text-text-quaternary"></span>
    </button>
    """
  end

  ## ── Sections ───────────────────────────────────────────────────

  defp primary_action(assigns) do
    ~H"""
    <button
      type="button"
      data-quick-create-trigger
      class={[
        "btn-press w-full flex items-center gap-2.5 px-3 py-2.5 rounded-xl shadow-card",
        "text-[13px] font-510 text-text-primary",
        "bg-brand/15 hover:bg-brand/25 border border-brand/30 hover:border-brand/50",
        "hover:shadow-[0_0_20px_rgba(217,119,87,0.25)]",
        "transition-[box-shadow,background-color,border-color] duration-300",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
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
  attr :advanced_only, :boolean, default: false

  defp section_header(assigns) do
    ~H"""
    <div class={[
      "flex items-center justify-between px-3 pt-3 pb-1",
      @advanced_only && "ui-advanced-only"
    ]}>
      <span class="text-[11px] font-510 tracking-[0.06em] text-text-quaternary">
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

  ## ── Collapsible section (Projects / Agents) ────────────────────

  attr :key, :string, required: true
  attr :label, :string, required: true
  attr :action_to, :string, default: nil
  attr :action_label, :string, default: nil
  slot :inner_block, required: true

  defp nav_section(assigns) do
    ~H"""
    <div data-nav-section={@key} class="pt-3">
      <div class="flex items-center justify-between px-3 pb-1">
        <button
          type="button"
          data-nav-toggle={@key}
          aria-expanded="true"
          class="group flex items-center gap-1 -ml-0.5 rounded text-[11px] font-510 tracking-[0.06em] text-text-quaternary hover:text-text-secondary transition-colors"
        >
          <span
            data-nav-chevron
            class="hero-chevron-down-mini w-3 h-3 shrink-0 transition-transform duration-150"
          >
          </span>
          <span>{@label}</span>
        </button>
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
      <div data-nav-body class="space-y-0.5">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :key, :string, required: true
  attr :count, :integer, required: true

  defp show_more(assigns) do
    ~H"""
    <button
      type="button"
      data-nav-show-more={@key}
      class="block w-full px-3 py-1.5 text-left text-[12px] text-text-quaternary hover:text-text-secondary transition-colors"
    >
      <span data-nav-more>Show {@count} more…</span>
      <span data-nav-less class="hidden">Show less</span>
    </button>
    """
  end

  ## ── Top-level link ─────────────────────────────────────────────

  attr :to, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :current_path, :string, required: true
  attr :badge, :integer, default: 0
  # Optional path used for the active-highlight test instead of `to`, so a link
  # can navigate to one route (e.g. /settings/profile) yet stay highlighted
  # across a whole section (e.g. any /settings/*).
  attr :match, :string, default: nil
  # Hidden while the UI is in simple mode.
  attr :advanced_only, :boolean, default: false

  defp nav_link(assigns) do
    active? = active?(assigns.match || assigns.to, assigns.current_path)
    assigns = assign(assigns, :active?, active?)

    ~H"""
    <.link
      navigate={@to}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-lg text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary",
        @advanced_only && "ui-advanced-only"
      ]}
      data-nav-path={@to}
      data-active={if @active?, do: "true", else: "false"}
      aria-current={if @active?, do: "page", else: nil}
    >
      <span class={[@icon, "w-4 h-4 shrink-0"]}></span>
      <span class="flex-1 truncate">{@label}</span>
      <span
        :if={@badge && @badge > 0}
        class="inline-flex items-center justify-center min-w-[18px] h-[18px] px-1 rounded-full bg-brand text-on-primary text-[10px] font-590"
        data-testid={"nav-badge-#{badge_key(@label)}"}
      >
        {@badge}
      </span>
    </.link>
    """
  end

  defp badge_key(label) do
    label
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  ## ── Project row ────────────────────────────────────────────────

  attr :project, :map, required: true
  attr :current_path, :string, required: true
  attr :overflow?, :boolean, default: false

  defp project_row(assigns) do
    href = ~p"/projects/#{assigns.project.id}"
    assigns = assign(assigns, :href, href)
    assigns = assign(assigns, :active?, active?(href, assigns.current_path))

    ~H"""
    <.link
      navigate={@href}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-lg text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary",
        @overflow? && "hidden"
      ]}
      data-nav-path={@href}
      data-nav-overflow={if @overflow?, do: "true"}
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
  attr :overflow?, :boolean, default: false

  defp agent_row(assigns) do
    href = ~p"/agents/#{assigns.agent.id}"
    assigns = assign(assigns, :href, href)
    assigns = assign(assigns, :active?, active?(href, assigns.current_path))

    ~H"""
    <.link
      navigate={@href}
      class={[
        "nav-item flex items-center gap-2.5 px-3 py-1.5 rounded-lg text-[13px] font-510 transition-colors",
        "text-text-secondary hover:bg-surface-hover hover:text-text-primary",
        @overflow? && "hidden"
      ]}
      data-nav-path={@href}
      data-nav-overflow={if @overflow?, do: "true"}
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

  defp status_color(:running), do: "#5db872"
  defp status_color(:active), do: "#5db872"
  defp status_color(:sleeping), do: "#e8a55a"
  defp status_color(:paused), do: "#e8a55a"
  defp status_color(:pending_approval), do: "#9A7CA8"
  defp status_color(:error), do: "#D97757"
  defp status_color(:offline), do: "#423F3B"
  defp status_color(:terminated), do: "#423F3B"
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
