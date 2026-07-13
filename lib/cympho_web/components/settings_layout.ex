defmodule CymphoWeb.Components.SettingsLayout do
  @moduledoc """
  Shared chrome for the Settings hub: a vertical, grouped sub-nav
  (Account / Workspace / Governance) on the left and the active tab's
  content on the right.

  Each settings tab is its own LiveView living in `live_session :default`.
  It renders its body inside `<.settings_layout active={:tab_key}> … </.settings_layout>`
  and the shell highlights the matching nav item. Tabs link to one another with
  `<.link navigate>` — because every settings route shares the one `live_session`,
  that's a fast LiveView live-redirect, not a full page reload.

  Adding a tab is a one-line edit to `@groups` below (key, label, path, icon).
  Tailwind scans `.ex` files, so the literal `hero-*` icon strings here are
  generated without a safelist entry.
  """
  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: CymphoWeb.Endpoint,
    router: CymphoWeb.Router

  # `<.page>` / `<.header>` live in CymphoWeb.Components; a component module's own
  # ~H body needs them imported explicitly (templates get them via html_helpers).
  import CymphoWeb.Components, only: [page: 1]

  # {group_label, [{key, label, path, icon}]}. Order here is the render order.
  @groups [
    {"Account",
     [
       {:profile, "Profile", "/settings/profile", "hero-user-circle-mini"},
       {:appearance, "Appearance", "/settings/appearance", "hero-swatch-mini"},
       {:notifications, "Notifications", "/settings/notifications", "hero-bell-mini"}
     ]},
    {"Workspace",
     [
       {:integrations, "Integrations", "/settings/integrations", "hero-puzzle-piece-mini"},
       {:adapters, "Adapters", "/settings/adapters", "hero-cpu-chip-mini"},
       {:secrets, "Secrets", "/settings/secrets", "hero-key-mini"},
       {:proxies, "Proxies", "/settings/proxies", "hero-globe-alt-mini"}
     ]},
    {"Governance",
     [
       {:policies, "Execution policies", "/settings/policies", "hero-shield-check-mini"},
       {:audit, "Audit log", "/settings/audit", "hero-clipboard-document-list-mini"}
     ]}
  ]

  @doc """
  Renders the settings page shell. `active` is the atom key of the current tab
  (see `@groups`); `inner_block` is the tab's own content (typically starting
  with its `<.header>`).
  """
  attr :active, :atom, required: true
  slot :inner_block, required: true

  def settings_layout(assigns) do
    assigns = assign(assigns, :groups, @groups)

    ~H"""
    <.page size="wide" data-ui-complex-page class="ember-aurora">
      <div class="relative z-[1] grid gap-6 lg:grid-cols-[220px_minmax(0,1fr)] lg:gap-8">
        <nav class="min-w-0 lg:sticky lg:top-6 lg:self-start" aria-label="Settings sections">
          <p class="ember-ink mb-3 px-1 font-serif text-lg font-510 tracking-[-0.01em] lg:mb-4 lg:px-3">
            Settings
          </p>
          <div class="flex gap-2 overflow-x-auto pb-2 lg:block lg:space-y-5 lg:overflow-visible lg:pb-0">
            <div :for={{group, items} <- @groups} class="contents lg:block lg:space-y-0.5">
              <p class="hidden px-3 pb-1 text-eyebrow uppercase text-text-quaternary lg:block">
                {group}
              </p>
              <.link
                :for={{key, label, path, icon} <- items}
                navigate={path}
                aria-current={(@active == key && "page") || nil}
                class={settings_nav_class(@active == key)}
              >
                <span class={[
                  icon,
                  "h-4 w-4 shrink-0",
                  (@active == key && "text-brand") ||
                    "text-text-tertiary group-hover:text-text-primary"
                ]}>
                </span>
                <span class="flex-1 truncate text-left">{label}</span>
              </.link>
            </div>
          </div>
        </nav>

        <div class="min-w-0">
          {render_slot(@inner_block)}
        </div>
      </div>
    </.page>
    """
  end

  defp settings_nav_class(active?) do
    [
      "group flex shrink-0 items-center gap-2.5 whitespace-nowrap rounded-lg border px-3 py-2 text-[13px] font-510 transition-colors lg:border-transparent lg:py-1.5",
      (active? &&
         "order-first border-brand/30 bg-brand/10 text-text-primary shadow-[0_10px_30px_-14px_rgb(var(--color-primary-rgb)/0.6)] lg:order-none lg:border-transparent") ||
        "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary lg:bg-transparent"
    ]
  end
end
