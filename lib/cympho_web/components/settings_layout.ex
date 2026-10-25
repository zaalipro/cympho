defmodule CymphoWeb.Components.SettingsLayout do
  @moduledoc """
  Shared chrome for the Settings hub (r3 P8): the grouped section nav
  (Company · Connections · You · Labels) beside the active section, in the r3
  root frame (H1 "Settings").

  Settings opens on Company › Details (`CymphoWeb.SettingsLive.Company`, an r3
  page that renders `settings_nav/1` under its Next step). Every other section
  is its own LiveView in `live_session :default` that renders its body inside
  `<.settings_layout active={:key}> … </.settings_layout>`; the nav marks the
  matching item. Sections link with `<.link navigate>`, a live redirect within
  the session. On phones Settings shows the section list; a section link
  (`?section=`) opens that section as its own page.

  Adding a section is a one-line edit to `@groups` below (key, label, path,
  Advanced-only?). Members and Billing are sections of the Company page.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [page_frame: 1, r3_icon: 1]

  # {group label or nil, [{key, label, path, advanced?}]}. Order here is the render order.
  @groups [
    {"Company",
     [
       {:details, "Details", "/settings/company?section=details", false},
       {:members, "Members", "/settings/company?section=members", false},
       {:billing, "Billing", "/settings/company?section=billing", false},
       {:policies, "Review steps", "/settings/policies", false},
       {:audit, "Audit log", "/settings/audit", false}
     ]},
    {"Connections",
     [
       {:adapters, "How agents run", "/settings/adapters", false},
       {:integrations, "Integrations", "/settings/integrations", false},
       {:secrets, "Keys and secrets", "/settings/secrets", false},
       {:proxies, "Network proxies", "/settings/proxies", true},
       {:plugins, "Plugins", "/plugins", true}
     ]},
    {"You",
     [
       {:profile, "Profile", "/settings/profile", false},
       {:appearance, "Appearance", "/settings/appearance", false},
       {:notifications, "Alerts", "/settings/notifications", false}
     ]},
    {nil, [{:labels, "Labels", "/labels", false}]}
  ]

  @doc """
  A settings section in the r3 root frame titled "Settings" (v7 §3.1 B12): the
  section nav and the section's own content. `picked` keeps the phone rule
  (money.css) from hiding `.set-main`; `data-section` scopes section CSS.
  """
  attr :active, :atom, required: true
  slot :inner_block, required: true

  def settings_layout(assigns) do
    ~H"""
    <.page_frame page="settings" title="Settings" tray_class="set-page" data-ui-complex-page>
      <div class="set picked">
        <.settings_nav active={@active} />
        <div class="set-main" data-section={@active}>{render_slot(@inner_block)}</div>
      </div>
    </.page_frame>
    """
  end

  @doc "The grouped section nav; `active` is the current section's key."
  attr :active, :atom, required: true

  def settings_nav(assigns) do
    assigns = assign(assigns, :groups, Enum.with_index(@groups))

    ~H"""
    <nav class="snav" aria-label="Settings sections">
      <div :for={{{group, items}, n} <- @groups}>
        <p :if={group} class="sn-g" id={"sn-#{n}"}>{group}</p>
        <ul aria-labelledby={group && "sn-#{n}"}>
          <li :for={{key, label, path, advanced?} <- items} class={advanced? && "ui-advanced-only"}>
            <.link navigate={path} aria-current={@active == key && "page"}>
              {label}<.r3_icon name="i-chev-right" class="ico s16 chv" />
            </.link>
          </li>
        </ul>
      </div>
    </nav>
    """
  end
end
