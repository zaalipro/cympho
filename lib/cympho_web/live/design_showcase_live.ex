defmodule CymphoWeb.DesignShowcaseLive do
  @moduledoc """
  Dev/test-only design prototype for the "Refined dark, craft-grade" redesign.

  Everything renders inside a `[data-theme="v2"]` wrapper so the new token
  values (defined in `assets/css/app.css`) apply here WITHOUT touching any
  production screen. All data is mock — no DB, no side effects.

  Sections: Tokens (palette + elevation + type scale), Components (buttons,
  badges, cards, metrics, inputs), and the five redesigned hero screens
  (Command Center, Kanban, Inbox, Integrations, Marketplace) each framed
  with a mock v2 sidebar for in-context review.

  Mounted in router.ex only when `Mix.env() in [:dev, :test]`. Removed at the
  start of Phase 3 once production *is* the redesign.
  """

  use CymphoWeb, :live_view

  @tabs [
    {"tokens", "Tokens"},
    {"components", "Components"},
    {"dashboard", "Command Center"},
    {"kanban", "Kanban"},
    {"inbox", "Inbox"},
    {"integrations", "Integrations"},
    {"marketplace", "Marketplace"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Design preview")
     |> assign(:section, "tokens")
     |> assign(:tabs, @tabs)}
  end

  @impl true
  def handle_event("section", %{"section" => section}, socket) do
    {:noreply, assign(socket, :section, section)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-theme="v2" class="min-h-screen bg-canvas font-sans text-text-primary">
      <div class="mx-auto w-full max-w-[1240px] px-5 py-7">
        <div class="mb-6 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0">
            <p class="text-eyebrow uppercase text-text-quaternary">Design preview · refined dark</p>
            <h1 class="mt-1 text-headline text-text-primary">Cympho v2</h1>
            <p class="mt-1 max-w-2xl text-body-sm text-text-tertiary">
              Lifted canvas, real elevation, an activated type scale and a restrained indigo accent.
              The rest of the app is unchanged — open any real route in another tab to compare.
            </p>
          </div>
          <span class="inline-flex shrink-0 items-center gap-1.5 self-start rounded-pill border border-brand/30 bg-brand/10 px-2.5 py-1 text-caption font-510 text-brand">
            <span class="h-1.5 w-1.5 rounded-full bg-brand"></span> data-theme="v2"
          </span>
        </div>

        <div class="mb-7 flex flex-wrap gap-1 rounded-lg border border-border bg-surface p-1 shadow-card">
          <button
            :for={{key, label} <- @tabs}
            type="button"
            phx-click="section"
            phx-value-section={key}
            class={[
              "rounded-md px-3 py-1.5 text-button transition-colors",
              if(@section == key,
                do: "bg-surface-hover text-text-primary shadow-[inset_0_0_0_1px_var(--color-border)]",
                else: "text-text-tertiary hover:bg-surface-hover/60 hover:text-text-primary"
              )
            ]}
          >
            {label}
          </button>
        </div>

        <%= case @section do %>
          <% "tokens" -> %>
            <.tokens_section />
          <% "components" -> %>
            <.components_section />
          <% "dashboard" -> %>
            <.frame><.dashboard_preview /></.frame>
          <% "kanban" -> %>
            <.frame><.kanban_preview /></.frame>
          <% "inbox" -> %>
            <.frame><.inbox_preview /></.frame>
          <% "integrations" -> %>
            <.frame><.integrations_preview /></.frame>
          <% "marketplace" -> %>
            <.frame><.marketplace_preview /></.frame>
        <% end %>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Tokens
  # ----------------------------------------------------------------

  defp tokens_section(assigns) do
    assigns =
      assign(assigns, :surfaces, [
        {"canvas", "#0a0b0e", "bg-canvas"},
        {"surface-1 / panel", "#14161b", "bg-surface-1"},
        {"surface-2 / surface", "#181b22", "bg-surface-2"},
        {"surface-3 / hover", "#1c1f26", "bg-surface-3"},
        {"surface-4", "#262b34", "bg-surface-4"}
      ])

    ~H"""
    <div class="space-y-8">
      <section>
        <.section_heading eyebrow="Palette" title="Surface ladder" />
        <div class="grid grid-cols-2 gap-3 sm:grid-cols-5">
          <div
            :for={{name, hex, bg} <- @surfaces}
            class="rounded-lg border border-border bg-surface-1 p-1 shadow-card"
          >
            <div class={["h-16 w-full rounded-md border border-border", bg]}></div>
            <div class="px-2 py-2">
              <p class="text-caption font-510 text-text-secondary">{name}</p>
              <p class="font-mono text-[11px] text-text-quaternary">{hex}</p>
            </div>
          </div>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Legibility" title="Ink on surfaces" />
        <div class="grid gap-3 sm:grid-cols-3">
          <div
            :for={surface <- ["bg-surface-1", "bg-surface-2", "bg-surface-3"]}
            class={["rounded-lg border border-border p-4 shadow-card", surface]}
          >
            <p class="text-body-sm font-590 text-text-primary">Primary ink — f7f8f8</p>
            <p class="text-body-sm text-text-secondary">Muted ink — d0d6e0</p>
            <p class="text-body-sm text-text-tertiary">Subtle ink — 8a8f98</p>
            <p class="text-body-sm text-text-quaternary">Quaternary — 6b7077</p>
          </div>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Depth" title="Elevation scale" />
        <div class="grid gap-4 sm:grid-cols-3">
          <div class="rounded-lg border border-border bg-surface-1 p-5 shadow-subtle">
            <p class="text-body-sm font-590 text-text-primary">shadow-subtle</p>
            <p class="text-caption text-text-tertiary">flat rows, list items</p>
          </div>
          <div class="rounded-lg border border-border bg-surface-1 p-5 shadow-card">
            <p class="text-body-sm font-590 text-text-primary">shadow-card</p>
            <p class="text-caption text-text-tertiary">resting cards + panels</p>
          </div>
          <div class="rounded-lg border border-border bg-surface-1 p-5 shadow-raised">
            <p class="text-body-sm font-590 text-text-primary">shadow-raised</p>
            <p class="text-caption text-text-tertiary">hover-lift, popovers</p>
          </div>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Accent" title="Indigo, used with intent" />
        <div class="flex flex-wrap items-center gap-4 rounded-lg border border-border bg-surface-1 p-5 shadow-card">
          <div class="h-12 w-12 rounded-lg bg-brand"></div>
          <div class="h-12 w-12 rounded-lg bg-accent-hover"></div>
          <div class="h-12 w-12 rounded-lg border border-brand/30 bg-brand/10"></div>
          <button
            type="button"
            class="rounded-lg bg-brand bg-gradient-to-b from-white/[0.10] to-transparent px-4 py-2 text-button text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] btn-press hover:bg-accent-hover"
          >
            Focus me (Tab)
          </button>
          <p class="text-caption text-text-quaternary">
            Tab to a control to see the soft focus glow.
          </p>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Type" title="Scale, finally used" />
        <div class="space-y-2 rounded-lg border border-border bg-surface-1 p-6 shadow-card">
          <p class="text-display-md text-text-primary">Display · 40px</p>
          <p class="text-headline text-text-primary">Headline · 28px page titles</p>
          <p class="text-card-title text-text-primary">Card title · 22px</p>
          <p class="text-subhead text-text-secondary">Subhead · 20px</p>
          <p class="text-body text-text-secondary">Body · 16px — the default reading size.</p>
          <p class="text-body-sm text-text-tertiary">Body small · 14px — secondary copy.</p>
          <p class="text-eyebrow uppercase text-text-quaternary">Eyebrow · 13px tracked caps</p>
          <p class="text-mono text-text-tertiary">Mono · 13px tabular 0123456789</p>
        </div>
      </section>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Components
  # ----------------------------------------------------------------

  defp components_section(assigns) do
    ~H"""
    <div class="space-y-8">
      <section>
        <.section_heading eyebrow="Actions" title="Buttons" />
        <div class="flex flex-wrap items-center gap-3 rounded-lg border border-border bg-surface-1 p-5 shadow-card">
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-lg bg-brand bg-gradient-to-b from-white/[0.10] to-transparent px-4 py-2 text-button text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] btn-press hover:bg-accent-hover"
          >
            Primary
          </button>
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-lg border border-border bg-button px-4 py-2 text-button text-text-primary btn-press hover:bg-button-hover"
          >
            Secondary
          </button>
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-lg px-4 py-2 text-button text-text-secondary btn-press hover:bg-surface-hover"
          >
            Ghost
          </button>
          <button
            type="button"
            class="inline-flex items-center gap-2 rounded-lg bg-error px-4 py-2 text-button text-white btn-press hover:bg-red-600"
          >
            Danger
          </button>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Signals" title="Badges & pills" />
        <div class="flex flex-wrap items-center gap-2 rounded-lg border border-border bg-surface-1 p-5 shadow-card">
          <.pill text="In progress" tone="brand" />
          <.pill text="Done" tone="success" />
          <.pill text="Blocked" tone="danger" />
          <.pill text="In review" tone="neutral" />
          <.pill text="Attention" tone="warning" />
          <span class="inline-flex items-center gap-1.5 rounded-pill border border-border px-2.5 py-0.5 text-caption text-text-secondary">
            <span class="h-1.5 w-1.5 rounded-full bg-red-400"></span> High
          </span>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Containers" title="Cards (hover to lift)" />
        <div class="grid gap-4 sm:grid-cols-3">
          <div
            :for={n <- 1..3}
            class="card-lift rounded-lg border border-border bg-surface-1 p-5 shadow-card hover:shadow-raised"
          >
            <p class="text-body-sm font-590 text-text-primary">Card {n}</p>
            <p class="mt-1 text-caption text-text-tertiary">
              Real elevation + a 2px lift on hover. Border brightens with the raised ring.
            </p>
          </div>
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Numbers" title="KPI cells" />
        <div class="grid grid-cols-2 divide-y divide-border rounded-lg border border-border bg-surface-1 shadow-card sm:grid-cols-4 sm:divide-y-0 sm:divide-x">
          <.kpi_cell label="Queued" value="6" hint="awaiting pickup" />
          <.kpi_cell label="Running" value="7" hint="checked out · 9/9" tone="brand" emphasis />
          <.kpi_cell label="Blocked" value="0" hint="needs action" />
          <.kpi_cell label="Closed 7d" value="14" hint="cost $0.00" />
        </div>
      </section>

      <section>
        <.section_heading eyebrow="Forms" title="Inputs & selects" />
        <div class="grid gap-4 rounded-lg border border-border bg-surface-1 p-5 shadow-card sm:grid-cols-2">
          <label class="space-y-1.5">
            <span class="block text-caption font-510 text-text-secondary">API key</span>
            <input
              type="text"
              placeholder="Leave blank to keep current key"
              class="w-full rounded-lg border border-border bg-surface px-3.5 py-2 text-body-sm text-text-primary placeholder:text-text-quaternary"
            />
          </label>
          <label class="space-y-1.5">
            <span class="block text-caption font-510 text-text-secondary">Cympho role</span>
            <select class="w-full appearance-none rounded-lg border border-border bg-surface px-3.5 py-2 text-body-sm text-text-primary">
              <option>Engineer</option>
              <option>Product Lead</option>
              <option>Design Lead</option>
            </select>
          </label>
        </div>
      </section>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Hero screen 1 — Command Center
  # ----------------------------------------------------------------

  defp dashboard_preview(assigns) do
    assigns =
      assigns
      |> assign(:agents, mock_agents())
      |> assign(:distribution, [
        {"Done", 6, "bg-success"},
        {"In progress", 7, "bg-brand"},
        {"To do", 6, "bg-sky-500"},
        {"Backlog", 3, "bg-text-quaternary"}
      ])
      |> assign(:inbox, Enum.take(mock_inbox(), 4))

    ~H"""
    <div class="space-y-4 p-5">
      <%!-- Hero + operating-mode, merged into one calm band --%>
      <div class="relative overflow-hidden rounded-xl border border-border bg-surface-1 shadow-card">
        <div
          class="pointer-events-none absolute inset-0"
          style="background: radial-gradient(ellipse 640px 240px at 0% 0%, rgba(94,106,210,0.10), transparent 60%);"
        >
        </div>
        <div class="pointer-events-none absolute inset-x-0 top-0 h-px bg-gradient-to-r from-transparent via-brand/40 to-transparent">
        </div>
        <div class="relative flex flex-col gap-4 px-6 py-5 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0">
            <div class="flex items-center gap-2 text-eyebrow uppercase text-text-quaternary">
              <span
                class="cympho-pulse-dot inline-block h-2 w-2 rounded-full bg-success"
                style="--cympho-pulse-color: #27a644;"
              >
              </span>
              <span class="text-text-tertiary">Autonomous company</span>
              <span class="text-text-quaternary/60">·</span>
              <span class="text-success">Active</span>
              <span class="text-text-quaternary/60">·</span>
              <span class="text-text-tertiary">Review mode</span>
            </div>
            <h1 class="mt-2 text-headline text-text-primary">Command Center</h1>
            <p class="mt-1 max-w-xl text-body-sm text-text-tertiary">
              Decide what the company should do next, then watch agents execute it.
            </p>
          </div>
          <button
            type="button"
            class="shrink-0 rounded-lg bg-brand bg-gradient-to-b from-white/[0.10] to-transparent px-3.5 py-2 text-button text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] btn-press hover:bg-accent-hover"
          >
            Open board
          </button>
        </div>
      </div>

      <%!-- One KPI instrument band, one emphasized hero number --%>
      <div class="grid grid-cols-2 divide-y divide-border rounded-xl border border-border bg-surface-1 shadow-card sm:grid-cols-3 sm:divide-y-0 sm:divide-x lg:grid-cols-5">
        <.kpi_cell label="Queued" value="6" hint="awaiting pickup" spark />
        <.kpi_cell label="Running" value="7" hint="checked out" tone="brand" emphasis />
        <.kpi_cell label="Blocked" value="0" hint="needs action" />
        <.kpi_cell label="Agents" value="9/9" hint="active capacity" />
        <.kpi_cell label="Closed 7d" value="14" hint="cost $0.00" spark />
      </div>

      <%!-- Calm work lists --%>
      <div class="grid gap-4 lg:grid-cols-3">
        <section class="rounded-xl border border-border bg-surface-1 p-4 shadow-card">
          <.section_heading eyebrow="Roster" title="Active agents" link="Org chart →" />
          <ul class="space-y-0.5">
            <li
              :for={a <- @agents}
              class="flex items-center gap-2.5 rounded-md border-l-2 border-transparent py-1.5 pl-2.5 pr-2 transition-colors hover:border-brand hover:bg-surface-hover/60"
            >
              <span class={[
                "flex h-6 w-6 items-center justify-center rounded-md text-[11px] font-590",
                role_chip(a.role)
              ]}>
                {a.glyph}
              </span>
              <span class="min-w-0 flex-1 truncate text-body-sm text-text-secondary">{a.name}</span>
              <span class={["h-1.5 w-1.5 rounded-full", status_dot(a.status)]}></span>
            </li>
          </ul>
        </section>

        <section class="rounded-xl border border-border bg-surface-1 p-4 shadow-card">
          <.section_heading eyebrow="Throughput" title="Issues by status" />
          <div class="mt-1 flex h-2.5 w-full overflow-hidden rounded-full bg-surface-3">
            <span
              :for={{_label, count, bg} <- @distribution}
              class={bg}
              style={"width: #{pct(count, 22)}%"}
            >
            </span>
          </div>
          <ul class="mt-4 space-y-2">
            <li
              :for={{label, count, bg} <- @distribution}
              class="flex items-center gap-2 text-body-sm"
            >
              <span class={["h-2 w-2 rounded-full", bg]}></span>
              <span class="flex-1 text-text-tertiary">{label}</span>
              <span class="font-mono tabular-nums text-text-secondary">{count}</span>
            </li>
          </ul>
        </section>

        <section class="rounded-xl border border-border bg-surface-1 p-4 shadow-card">
          <.section_heading eyebrow="Activity" title="Inbox" link="Open inbox →" />
          <ul class="space-y-0.5">
            <li
              :for={item <- @inbox}
              class="rounded-md border-l-2 border-transparent py-1.5 pl-2.5 pr-1 transition-colors hover:border-brand hover:bg-surface-hover/60"
            >
              <p class="truncate text-body-sm text-text-secondary">
                <span class="font-mono text-[11px] text-text-quaternary">{item.ident}</span>
                · {item.title}
              </p>
              <p class="text-caption text-text-quaternary">{item.to} · {item.time}</p>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Hero screen 2 — Kanban
  # ----------------------------------------------------------------

  defp kanban_preview(assigns) do
    assigns = assign(assigns, :columns, mock_columns())

    ~H"""
    <div class="p-5">
      <div class="mb-4">
        <h1 class="text-headline text-text-primary">Kanban board</h1>
        <p class="mt-1 text-body-sm text-text-tertiary">
          Review mode — reshape work safely without starting agent runs.
        </p>
      </div>

      <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
        <section
          :for={col <- @columns}
          class="flex flex-col rounded-xl border border-border bg-surface-1/60 shadow-card"
        >
          <header class={[
            "flex items-center justify-between rounded-t-xl border-b border-border border-l-2 bg-surface-1 px-3 py-2.5",
            col.accent
          ]}>
            <span class="text-body-sm font-590 text-text-primary">{col.name}</span>
            <span class="rounded-pill bg-surface-3 px-2 py-0.5 font-mono text-[11px] tabular-nums text-text-tertiary">
              {length(col.cards)}
            </span>
          </header>
          <div class="flex flex-col gap-2 p-2">
            <article
              :for={card <- col.cards}
              class="card-lift cursor-grab rounded-lg border border-border bg-surface-2 p-3 shadow-subtle hover:border-border-hover hover:shadow-raised"
            >
              <div class="flex items-center justify-between">
                <span class="font-mono text-[11px] text-text-quaternary">{card.ident}</span>
                <span class="flex items-center gap-1.5 text-caption text-text-tertiary">
                  <span class={["h-1.5 w-1.5 rounded-full", priority_dot(card.priority)]}></span>
                  {card.priority}
                </span>
              </div>
              <p class="mt-1.5 line-clamp-2 text-body-sm font-590 leading-5 text-text-primary">
                {card.title}
              </p>
              <div class="mt-2 flex items-center gap-1.5">
                <.pill text={card.state_label} tone={card.state_tone} small />
                <span class="line-clamp-1 text-[11px] text-text-tertiary">{card.signal}</span>
              </div>
              <div class="mt-2.5 flex items-center gap-3 text-[11px] text-text-quaternary">
                <span class="flex items-center gap-1">
                  <.icon name="hero-chat-bubble-left-mini" class="h-3 w-3" /> {card.comments}
                </span>
                <span>{card.assignee}</span>
              </div>
            </article>
            <p
              :if={col.cards == []}
              class="rounded-lg border border-dashed border-border bg-surface-1/40 px-3 py-8 text-center text-caption text-text-quaternary"
            >
              Nothing to review
            </p>
          </div>
        </section>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Hero screen 3 — Inbox
  # ----------------------------------------------------------------

  defp inbox_preview(assigns) do
    assigns = assign(assigns, :items, mock_inbox())

    ~H"""
    <div class="p-5">
      <div class="mb-4 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h1 class="text-headline text-text-primary">Inbox</h1>
          <p class="mt-1 text-body-sm text-text-tertiary">
            Agent handoffs, review signals and issue notifications.
          </p>
        </div>
        <div class="flex items-center gap-2">
          <div class="inline-flex rounded-lg border border-border bg-surface p-1">
            <button
              type="button"
              class="rounded-md bg-surface-hover px-3 py-1.5 text-caption text-text-primary shadow-[inset_0_0_0_1px_var(--color-border)]"
            >
              All <span class="text-text-quaternary">9</span>
            </button>
            <button
              type="button"
              class="rounded-md px-3 py-1.5 text-caption text-text-tertiary hover:text-text-primary"
            >
              Unread <span class="text-text-quaternary">1</span>
            </button>
            <button
              type="button"
              class="rounded-md px-3 py-1.5 text-caption text-text-tertiary hover:text-text-primary"
            >
              Review <span class="text-text-quaternary">6</span>
            </button>
          </div>
        </div>
      </div>

      <div class="space-y-2.5">
        <article
          :for={item <- @items}
          class={[
            "card-lift grid gap-4 rounded-lg border border-border bg-surface-1 p-4 shadow-card hover:shadow-raised lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start",
            item.unread && "border-l-2 border-l-brand"
          ]}
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2 text-caption text-text-quaternary">
              <span class={[
                "h-1.5 w-1.5 rounded-full",
                (item.unread && "bg-brand") || "bg-text-quaternary"
              ]}>
              </span>
              <span class={(item.unread && "font-510 text-text-secondary") || "text-text-tertiary"}>
                {(item.unread && "Unread") || "Read"}
              </span>
              <span>·</span>
              <span>To {item.to}</span>
              <span>·</span>
              <span>{item.time}</span>
              <span
                :if={item.flag}
                class="rounded-pill border border-amber-500/35 bg-amber-500/10 px-2 py-0.5 text-[11px] text-amber-300"
              >
                {item.flag}
              </span>
            </div>
            <p class="mt-1.5 text-subhead font-590 leading-6 text-text-primary">
              <span class="font-mono text-[13px] text-text-quaternary">{item.ident}</span>
              · {item.title}
            </p>
            <div class="mt-2 flex items-center gap-1.5">
              <.pill text={item.state_label} tone={item.state_tone} small />
              <span class="line-clamp-1 text-body-sm text-text-tertiary">{item.signal}</span>
            </div>
          </div>
          <div class="flex flex-wrap gap-2 lg:justify-end">
            <button
              type="button"
              class="rounded-lg bg-brand bg-gradient-to-b from-white/[0.10] to-transparent px-3 py-1.5 text-button text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] btn-press hover:bg-accent-hover"
            >
              Open issue
            </button>
            <button
              type="button"
              class="rounded-lg border border-border bg-surface px-3 py-1.5 text-button text-text-secondary btn-press hover:bg-surface-hover"
            >
              Dismiss
            </button>
          </div>
        </article>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Hero screen 4 — Integrations
  # ----------------------------------------------------------------

  defp integrations_preview(assigns) do
    ~H"""
    <div class="p-5">
      <div class="mb-4">
        <h1 class="text-headline text-text-primary">Integrations</h1>
        <p class="mt-1 text-body-sm text-text-tertiary">
          Connect company-level services that extend how Cympho agents work.
        </p>
      </div>

      <div class="grid gap-4 xl:grid-cols-[minmax(0,1fr)_340px]">
        <section class="overflow-hidden rounded-xl border border-border bg-surface-1 shadow-card">
          <div class="pointer-events-none h-px bg-gradient-to-r from-transparent via-success/40 to-transparent">
          </div>
          <div class="bg-gradient-to-b from-surface-2/50 to-transparent px-6 py-5">
            <div class="flex items-start gap-3">
              <span class="flex h-10 w-10 items-center justify-center rounded-lg border border-brand/25 bg-brand/10 text-brand">
                <.icon name="hero-sparkles-mini" class="h-5 w-5" />
              </span>
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <h2 class="text-card-title text-text-primary">Agrenting</h2>
                  <span class="inline-flex items-center gap-1.5 rounded-pill border border-success/35 bg-success/10 px-2 py-0.5 text-caption font-510 text-success">
                    <span class="h-1.5 w-1.5 rounded-full bg-success"></span> Connected
                  </span>
                </div>
                <p class="mt-1 max-w-md text-body-sm text-text-tertiary">
                  Hire marketplace agents and run them from Cympho without exposing the API key to individual users.
                </p>
              </div>
            </div>
          </div>
          <div class="grid gap-5 px-6 py-5 sm:grid-cols-2">
            <label class="space-y-1.5">
              <span class="block text-caption font-510 text-text-secondary">API key</span>
              <input
                type="text"
                placeholder="Leave blank to keep current key"
                class="w-full rounded-lg border border-border bg-surface px-3.5 py-2 text-body-sm text-text-primary placeholder:text-text-quaternary"
              />
            </label>
            <label class="space-y-1.5">
              <span class="block text-caption font-510 text-text-secondary">Base URL</span>
              <input
                type="text"
                value="https://www.agrenting.com"
                class="w-full rounded-lg border border-border bg-surface px-3.5 py-2 text-body-sm text-text-primary"
              />
            </label>
            <label class="space-y-1.5 sm:col-span-2">
              <span class="block text-caption font-510 text-text-secondary">Repo access token</span>
              <input
                type="text"
                placeholder="Optional token for push delivery"
                class="w-full rounded-lg border border-border bg-surface px-3.5 py-2 text-body-sm text-text-primary placeholder:text-text-quaternary"
              />
            </label>
          </div>
          <div class="flex items-center justify-end gap-2 border-t border-border px-6 py-4">
            <button
              type="button"
              class="rounded-lg px-3.5 py-2 text-button text-red-300 btn-press hover:bg-red-500/10"
            >
              Disconnect
            </button>
            <button
              type="button"
              class="rounded-lg border border-border bg-surface px-3.5 py-2 text-button text-text-secondary btn-press hover:bg-surface-hover"
            >
              Test
            </button>
            <button
              type="button"
              class="rounded-lg bg-brand bg-gradient-to-b from-white/[0.10] to-transparent px-3.5 py-2 text-button text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] btn-press hover:bg-accent-hover"
            >
              Save connection
            </button>
          </div>
        </section>

        <div class="space-y-4">
          <section class="rounded-xl border border-border bg-surface-1 p-5 shadow-card">
            <.section_heading eyebrow="Status" title="Connection state" />
            <dl class="divide-y divide-border text-body-sm">
              <.state_row label="API key" value="Stored" ok />
              <.state_row label="Marketplace" value="agrenting.com" mono />
              <.state_row label="URL mode" value="Default" />
              <.state_row label="Repo token" value="Not stored" />
            </dl>
          </section>
          <section class="rounded-xl border border-border bg-surface-1 p-5 shadow-card">
            <.section_heading eyebrow="Hiring" title="Remote hiring" />
            <p class="text-body-sm text-text-tertiary">
              Once connected, marketplace agents appear with pricing, capabilities and a local proxy agent record.
            </p>
            <button
              type="button"
              class="mt-4 w-full rounded-lg border border-border bg-surface px-3.5 py-2 text-button text-text-secondary btn-press hover:bg-surface-hover"
            >
              Browse agents
            </button>
          </section>
        </div>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Hero screen 5 — Marketplace
  # ----------------------------------------------------------------

  defp marketplace_preview(assigns) do
    assigns = assign(assigns, :agents, mock_marketplace())

    ~H"""
    <div class="p-5">
      <div class="mb-4">
        <h1 class="text-headline text-text-primary">Hire remote agent</h1>
        <p class="mt-1 text-body-sm text-text-tertiary">
          Browse Agrenting marketplace agents and connect them as Cympho operators.
        </p>
      </div>

      <div class="grid gap-4 xl:grid-cols-2">
        <article
          :for={agent <- @agents}
          class={[
            "card-lift rounded-xl border bg-surface-1 p-5 shadow-card hover:shadow-raised",
            (agent.connected && "border-brand/30 bg-brand/[0.04]") || "border-border"
          ]}
        >
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="text-card-title text-text-primary">{agent.name}</h2>
                <span class="rounded-pill border border-success/35 bg-success/10 px-2 py-0.5 text-[11px] font-510 text-success">
                  active
                </span>
                <span
                  :if={agent.connected}
                  class="rounded-pill border border-brand/35 bg-brand/10 px-2 py-0.5 text-[11px] font-510 text-brand"
                >
                  connected
                </span>
              </div>
              <p class="mt-1 font-mono text-[11px] text-text-quaternary">{agent.did}</p>
            </div>
            <div class="shrink-0 text-right">
              <p class="font-mono text-card-title tabular-nums text-text-primary">${agent.price}</p>
              <p class="text-caption text-text-quaternary">{agent.rating} ★ · {agent.model}</p>
            </div>
          </div>

          <div class="mt-3 flex flex-wrap gap-1.5">
            <span
              :for={tag <- agent.tags}
              class="rounded-pill border border-brand/20 bg-brand/10 px-2 py-0.5 text-[11px] text-brand"
            >
              {tag}
            </span>
          </div>

          <div class="mt-4 flex items-center justify-between gap-3 border-t border-border pt-4">
            <details class="min-w-0 flex-1">
              <summary class="cursor-pointer list-none text-button text-text-tertiary hover:text-text-primary">
                Configure hire ▾
              </summary>
              <div class="mt-3 grid gap-3 sm:grid-cols-2">
                <select class="w-full appearance-none rounded-lg border border-border bg-surface px-3 py-1.5 text-body-sm text-text-primary">
                  <option>Coding</option>
                </select>
                <select class="w-full appearance-none rounded-lg border border-border bg-surface px-3 py-1.5 text-body-sm text-text-primary">
                  <option>Engineer</option>
                </select>
              </div>
            </details>
            <button
              type="button"
              disabled={agent.connected}
              class={[
                "shrink-0 rounded-lg px-3.5 py-2 text-button btn-press",
                (agent.connected &&
                   "cursor-not-allowed border border-border bg-surface text-text-quaternary") ||
                  "bg-brand bg-gradient-to-b from-white/[0.10] to-transparent text-white shadow-[inset_0_1px_0_0_rgba(255,255,255,0.18)] hover:bg-accent-hover"
              ]}
            >
              {(agent.connected && "Connected") || "Hire in Cympho"}
            </button>
          </div>
        </article>
      </div>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Shared bits
  # ----------------------------------------------------------------

  slot :inner_block, required: true

  # Frame a hero preview alongside a mock v2 sidebar for in-context review.
  defp frame(assigns) do
    ~H"""
    <div class="overflow-hidden rounded-xl border border-border shadow-raised">
      <div class="flex">
        <.mock_sidebar />
        <div class="min-w-0 flex-1 bg-canvas">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp mock_sidebar(assigns) do
    assigns =
      assigns
      |> assign(:nav, [
        {"hero-squares-2x2-mini", "Dashboard", true},
        {"hero-view-columns-mini", "Board", false},
        {"hero-inbox-mini", "Inbox", false},
        {"hero-command-line-mini", "Operations", false}
      ])
      |> assign(:agents, Enum.take(mock_agents(), 5))

    ~H"""
    <aside class="hidden w-56 shrink-0 flex-col border-r border-border bg-surface-1 lg:flex">
      <div class="flex h-14 items-center gap-2 border-b border-border px-3">
        <span class="flex h-6 w-6 items-center justify-center rounded-md bg-brand/15 text-[11px] font-590 text-brand">
          CL
        </span>
        <span class="text-body-sm font-590 text-text-primary">Cympho Labs</span>
      </div>
      <div class="flex-1 space-y-0.5 overflow-y-auto px-2 py-2.5">
        <button
          type="button"
          class="mb-2 flex w-full items-center gap-2.5 rounded-md border border-brand/30 bg-brand/15 px-3 py-2 text-[13px] font-510 text-text-primary btn-press hover:bg-brand/25"
        >
          <.icon name="hero-pencil-square-mini" class="h-4 w-4 text-brand" /> New issue
        </button>
        <a
          :for={{icon, label, active} <- @nav}
          href="#"
          data-active={to_string(active)}
          class={[
            "flex items-center gap-2.5 rounded-md px-3 py-1.5 text-[13px] font-510 transition-colors",
            (active && "bg-surface-hover text-text-primary") ||
              "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
          ]}
        >
          <.icon name={icon} class="h-4 w-4" /> {label}
        </a>
        <p class="px-3 pb-1 pt-3 text-[10px] font-590 uppercase tracking-[0.08em] text-text-quaternary">
          Agents
        </p>
        <div
          :for={a <- @agents}
          class="flex items-center gap-2.5 rounded-md px-3 py-1.5 text-[13px] text-text-secondary"
        >
          <span class={[
            "flex h-5 w-5 items-center justify-center rounded text-[10px] font-590",
            role_chip(a.role)
          ]}>
            {a.glyph}
          </span>
          <span class="min-w-0 flex-1 truncate">{a.name}</span>
          <span class={["h-1.5 w-1.5 rounded-full", status_dot(a.status)]}></span>
        </div>
      </div>
      <div class="flex items-center gap-2.5 border-t border-border px-3 py-2.5">
        <span class="flex h-6 w-6 items-center justify-center rounded-full bg-surface-3 text-[10px] font-590 text-text-secondary">
          CO
        </span>
        <span class="text-[13px] text-text-secondary">Cympho Owner</span>
      </div>
    </aside>
    """
  end

  attr :eyebrow, :string, default: nil
  attr :title, :string, required: true
  attr :link, :string, default: nil

  defp section_heading(assigns) do
    ~H"""
    <div class="mb-3 flex items-end justify-between gap-3">
      <div class="min-w-0">
        <p :if={@eyebrow} class="text-eyebrow uppercase text-text-quaternary">{@eyebrow}</p>
        <h2 class="text-card-title text-text-primary">{@title}</h2>
      </div>
      <a
        :if={@link}
        href="#"
        class="shrink-0 text-caption font-510 text-brand hover:text-accent-hover"
      >
        {@link}
      </a>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "default"
  attr :emphasis, :boolean, default: false
  attr :spark, :boolean, default: false

  defp kpi_cell(assigns) do
    ~H"""
    <div class={["relative px-4 py-4", @emphasis && "bg-brand/[0.04]"]}>
      <span :if={@emphasis} class="absolute inset-y-0 left-0 w-0.5 bg-brand"></span>
      <p class="text-eyebrow uppercase text-text-quaternary">{@label}</p>
      <div class="mt-1.5 flex items-end justify-between gap-2">
        <span class={[
          "font-mono tabular-nums leading-none",
          (@emphasis && "text-display-md text-brand") || "text-[28px] #{kpi_tone(@tone)}"
        ]}>
          {@value}
        </span>
        <svg
          :if={@spark}
          viewBox="0 0 56 18"
          class="h-4 w-14 text-text-quaternary/50"
          fill="none"
          stroke="currentColor"
          stroke-width="1.2"
        >
          <polyline points="0,14 8,11 16,12 24,7 32,9 40,4 48,6 56,2" />
        </svg>
      </div>
      <p :if={@hint} class="mt-1.5 text-caption text-text-quaternary">{@hint}</p>
    </div>
    """
  end

  attr :text, :string, required: true
  attr :tone, :string, default: "neutral"
  attr :small, :boolean, default: false

  defp pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 rounded-pill font-510",
      (@small && "px-2 py-0.5 text-[11px]") || "px-2.5 py-0.5 text-caption",
      pill_tone(@tone)
    ]}>
      <span class={["h-1.5 w-1.5 rounded-full", pill_dot(@tone)]}></span>
      {@text}
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :ok, :boolean, default: false
  attr :mono, :boolean, default: false

  defp state_row(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-2.5">
      <dt class="text-text-tertiary">{@label}</dt>
      <dd class={["flex items-center gap-1.5 text-text-secondary", @mono && "font-mono text-[12px]"]}>
        <span :if={@ok} class="h-1.5 w-1.5 rounded-full bg-success"></span>
        {@value}
      </dd>
    </div>
    """
  end

  # ----------------------------------------------------------------
  # Mock data + small style helpers
  # ----------------------------------------------------------------

  defp mock_agents do
    [
      %{name: "CEO", role: :ceo, glyph: "C", status: :running},
      %{name: "CTO", role: :cto, glyph: "T", status: :running},
      %{name: "Design Lead", role: :design, glyph: "D", status: :active},
      %{name: "Engineer 1", role: :engineer, glyph: "E", status: :running},
      %{name: "Engineer 2", role: :engineer, glyph: "E", status: :sleeping},
      %{name: "Engineer 3", role: :engineer, glyph: "E", status: :idle}
    ]
  end

  defp mock_inbox do
    [
      %{
        unread: true,
        to: "CEO",
        time: "May 08, 18:30",
        ident: "CYM-12",
        flag: "Review evidence needed",
        title: "Owner request: reduce onboarding time by half",
        state_label: "Coordinating",
        state_tone: "warning",
        signal: "Splitting into product criteria, design flow and CTO execution planning."
      },
      %{
        unread: false,
        to: "Dia QA Engineer",
        time: "May 04, 15:14",
        ident: "CYM-1",
        flag: nil,
        title: "Create the first autonomous execution plan",
        state_label: "In progress",
        state_tone: "brand",
        signal: "Assigned, but no delivery evidence yet — start the agent or split the work."
      },
      %{
        unread: false,
        to: "Engineer 2",
        time: "May 04, 00:14",
        ident: "CYM-3",
        flag: nil,
        title: "Browser LiveView smoke issue",
        state_label: "Done",
        state_tone: "success",
        signal: "Closed — verification attached, PR merged."
      },
      %{
        unread: false,
        to: "Engineer 1",
        time: "May 03, 10:14",
        ident: "CYM-2",
        flag: nil,
        title: "Context smoke create",
        state_label: "In review",
        state_tone: "neutral",
        signal: "Waiting on CTO review before owner-visible closure."
      }
    ]
  end

  defp mock_columns do
    [
      %{
        name: "Backlog",
        accent: "border-l-text-quaternary",
        cards: [
          %{
            ident: "AIL-2",
            title: "Update readme",
            priority: "Medium",
            state_label: "Assigned",
            state_tone: "neutral",
            signal: "No agent signal yet.",
            comments: 0,
            assignee: "CEO"
          }
        ]
      },
      %{
        name: "To do",
        accent: "border-l-sky-500",
        cards: [
          %{
            ident: "CYM-18",
            title: "Multi-project smoke: Company OS ownership route",
            priority: "Medium",
            state_label: "Assigned",
            state_tone: "neutral",
            signal: "Awaiting pickup.",
            comments: 0,
            assignee: "CTO"
          }
        ]
      },
      %{
        name: "In progress",
        accent: "border-l-brand",
        cards: [
          %{
            ident: "CYM-8",
            title: "Autonomy smoke: split technical implementation",
            priority: "Critical",
            state_label: "Running",
            state_tone: "brand",
            signal: "Engineer 1 checked out 12m ago.",
            comments: 2,
            assignee: "CTO"
          }
        ]
      },
      %{name: "In review", accent: "border-l-amber-500", cards: []}
    ]
  end

  defp mock_marketplace do
    [
      %{
        name: "MiniMax M2.7 Free",
        connected: true,
        did: "did:agent:minimax-m2.7-free:agent-farm",
        price: "0.00",
        rating: "5.00",
        model: "minimax",
        tags: ["Coding"]
      },
      %{
        name: "MiniMax M2.7 General",
        connected: false,
        did: "did:agent:minimax-general:agent-farm",
        price: "0.20",
        rating: "5.00",
        model: "minimax",
        tags: ["Coding"]
      },
      %{
        name: "Kimi K2.6 Research",
        connected: false,
        did: "did:agent:kimi-k2.6-research:agent-farm",
        price: "0.30",
        rating: "5.00",
        model: "kimi",
        tags: ["Coding", "Research"]
      },
      %{
        name: "Qwen3.6 Plus Deep Research",
        connected: false,
        did: "did:agent:qwen3.6-plus-dr:agentfarm",
        price: "0.40",
        rating: "5.00",
        model: "qwen",
        tags: ["Data Analysis"]
      }
    ]
  end

  defp pct(count, total) when total > 0, do: Float.round(count / total * 100, 1)
  defp pct(_, _), do: 0

  defp role_chip(:ceo), do: "bg-brand/15 text-brand"
  defp role_chip(:cto), do: "bg-sky-500/15 text-sky-300"
  defp role_chip(:design), do: "bg-pink-500/15 text-pink-300"
  defp role_chip(_), do: "bg-emerald-500/15 text-emerald-300"

  defp status_dot(:running), do: "bg-emerald-400"
  defp status_dot(:active), do: "bg-emerald-400"
  defp status_dot(:sleeping), do: "bg-amber-400"
  defp status_dot(_), do: "bg-text-quaternary"

  defp priority_dot("Critical"), do: "bg-red-500"
  defp priority_dot("High"), do: "bg-red-400"
  defp priority_dot("Medium"), do: "bg-amber-400"
  defp priority_dot(_), do: "bg-text-quaternary"

  defp kpi_tone("brand"), do: "text-brand"
  defp kpi_tone("success"), do: "text-success"
  defp kpi_tone("danger"), do: "text-red-300"
  defp kpi_tone(_), do: "text-text-primary"

  defp pill_tone("brand"), do: "bg-brand/15 text-brand"
  defp pill_tone("success"), do: "bg-success/15 text-success"
  defp pill_tone("danger"), do: "bg-red-500/15 text-red-300"
  defp pill_tone("warning"), do: "bg-amber-500/15 text-amber-300"
  defp pill_tone(_), do: "bg-surface-3 text-text-tertiary"

  defp pill_dot("brand"), do: "bg-brand"
  defp pill_dot("success"), do: "bg-success"
  defp pill_dot("danger"), do: "bg-red-400"
  defp pill_dot("warning"), do: "bg-amber-400"
  defp pill_dot(_), do: "bg-text-quaternary"
end
