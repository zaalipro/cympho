defmodule CymphoWeb.Components do
  use Phoenix.Component

  # date_picker/time_picker/datetime_picker live in their own module; input/1
  # delegates to them, so they must be in scope here (not just in templates).
  import CymphoWeb.Components.DatePicker

  attr :size, :string, default: "wide"
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def page(assigns) do
    ~H"""
    <div class={["min-h-screen bg-canvas px-4 py-5 sm:px-6 lg:px-8", @class]} {@rest}>
      <div class={["mx-auto w-full", page_size(@size)]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :spark, :boolean, default: false
  attr :rest, :global
  slot :inner_block
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between" {@rest}>
      <div class="min-w-0">
        <h1 :if={@title} class="flex items-center gap-2 text-headline text-text-primary">
          <.spark :if={@spark} class="h-[0.85em] w-[0.85em] text-brand" />
          <span class="min-w-0 truncate">{@title}</span>
        </h1>
        <p :if={@subtitle} class="mt-1 max-w-2xl text-body-sm text-text-tertiary">
          {@subtitle}
        </p>
        {render_slot(@inner_block)}
      </div>
      <div
        :if={@actions != []}
        class="flex flex-wrap items-center gap-2 sm:flex-nowrap sm:justify-end"
      >
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :density, :string, required: true
  attr :compact_patch, :string, required: true
  attr :detailed_patch, :string, required: true
  attr :class, :any, default: nil

  def density_switch(assigns) do
    ~H"""
    <div
      class={[
        "inline-flex shrink-0 whitespace-nowrap rounded-xl border border-hairline bg-surface p-1",
        @class
      ]}
      data-density-switch
      data-density={@density}
      role="group"
      title="Change row detail with V"
      aria-label="Row detail"
    >
      <.link
        patch={@compact_patch}
        data-density-option="compact"
        role="button"
        aria-pressed={to_string(@density == "compact")}
        title="Compact rows (V)"
        class={[
          "inline-flex items-center rounded-lg px-2.5 py-1.5 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40",
          density_tab_class(@density, "compact")
        ]}
      >
        <span class="hero-list-bullet-mini h-4 w-4"></span>
        <span class="sr-only">Compact rows</span>
      </.link>
      <.link
        patch={@detailed_patch}
        data-density-option="detailed"
        role="button"
        aria-pressed={to_string(@density == "detailed")}
        title="Detailed rows (V)"
        class={[
          "inline-flex items-center rounded-lg px-2.5 py-1.5 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40",
          density_tab_class(@density, "detailed")
        ]}
      >
        <span class="hero-rectangle-stack-mini h-4 w-4"></span>
        <span class="sr-only">Detailed rows</span>
      </.link>
    </div>
    """
  end

  defp density_tab_class(current, density) do
    if current == density do
      "bg-surface-2 text-text-primary shadow-card"
    else
      "text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
    end
  end

  @doc """
  Renders an accessible icon-only action. The visible icon is always paired
  with a required accessible label and native tooltip.
  """
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :type, :string, default: "button"
  attr :disabled, :boolean, default: false
  attr :tone, :string, default: "neutral"
  attr :class, :any, default: nil
  attr :rest, :global

  def icon_action(%{navigate: navigate} = assigns) when is_binary(navigate) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-label={@label}
      title={@label}
      class={[icon_action_class(@tone), @class]}
      {@rest}
    >
      <span class={[@icon, "h-4 w-4"]}></span>
      <span class="sr-only">{@label}</span>
    </.link>
    """
  end

  def icon_action(%{patch: patch} = assigns) when is_binary(patch) do
    ~H"""
    <.link
      patch={@patch}
      aria-label={@label}
      title={@label}
      class={[icon_action_class(@tone), @class]}
      {@rest}
    >
      <span class={[@icon, "h-4 w-4"]}></span>
      <span class="sr-only">{@label}</span>
    </.link>
    """
  end

  def icon_action(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      aria-label={@label}
      title={@label}
      class={[icon_action_class(@tone), @class]}
      {@rest}
    >
      <span class={[@icon, "h-4 w-4"]}></span>
      <span class="sr-only">{@label}</span>
    </button>
    """
  end

  defp icon_action_class("danger") do
    "inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-red-500/25 bg-red-500/10 text-red-300 transition-colors hover:bg-red-500/15 hover:text-red-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-red-400/40"
  end

  defp icon_action_class(_tone) do
    "inline-flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border border-border bg-surface-2 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
  end

  @doc """
  A small 4-point terracotta "spark" glyph — Cympho's nod to Claude's warm
  accent motif. Decorative only (`aria-hidden`); deliberately a plain
  sparkle, not Claude's multi-spoke sunburst, and never used as the product
  logo. Pass size/color via `class` (defaults to `h-4 w-4 text-brand`).
  """
  attr :class, :any, default: "h-4 w-4 text-brand"

  def spark(assigns) do
    ~H"""
    <svg
      viewBox="0 0 24 24"
      fill="currentColor"
      class={["shrink-0", @class]}
      aria-hidden="true"
    >
      <path d="M12 2 L13.8 10.2 L22 12 L13.8 13.8 L12 22 L10.2 13.8 L2 12 L10.2 10.2 Z" />
    </svg>
    """
  end

  @doc """
  A streamed, infinite-scrolling list wrapper.

  The caller renders each item in the default slot by iterating `@streams.<key>`
  and setting `id={dom_id}` — this component never templates the items. Pairs with
  the `InfiniteScroll` JS hook and the `CymphoWeb.InfiniteScroll` helpers.

      <.infinite_scroll id="activity" has_more={@infinite_scroll[:activities].has_more?}>
        <:empty>Nothing here yet.</:empty>
        <div :for={{dom_id, a} <- @streams.activities} id={dom_id}>...</div>
      </.infinite_scroll>

  For `<table>` lists put `phx-update="stream"` on the `<tbody>` yourself and use
  `infinite_scroll_footer/1` after the table instead.
  """
  attr :id, :string, required: true, doc: "stable DOM id prefix for the container + sentinel"
  attr :has_more, :boolean, required: true
  attr :event, :string, default: "next-page"
  attr :target, :any, default: nil, doc: "optional phx-target for the next-page event"
  attr :root_margin, :string, default: "500px 0px"
  attr :end_label, :string, default: nil, doc: "optional caption shown once the list is exhausted"
  attr :container_class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :empty

  def infinite_scroll(assigns) do
    ~H"""
    <div id={"#{@id}-list"} phx-update="stream" class={@container_class} {@rest}>
      <div :if={@empty != []} id={"#{@id}-empty"} class="only:block hidden">
        {render_slot(@empty)}
      </div>
      {render_slot(@inner_block)}
    </div>
    <.infinite_scroll_footer
      id={@id}
      has_more={@has_more}
      event={@event}
      target={@target}
      root_margin={@root_margin}
      end_label={@end_label}
    />
    """
  end

  @doc """
  The sentinel + loading spinner (and optional end caption) for an infinite list.

  Use directly after a `<table>` whose `<tbody>` carries `phx-update="stream"`;
  `infinite_scroll/1` renders it for the non-table case.
  """
  attr :id, :string, required: true
  attr :has_more, :boolean, required: true
  attr :event, :string, default: "next-page"
  attr :target, :any, default: nil
  attr :root_margin, :string, default: "500px 0px"
  attr :end_label, :string, default: nil

  def infinite_scroll_footer(assigns) do
    ~H"""
    <div
      :if={@has_more}
      id={"#{@id}-sentinel"}
      phx-hook="InfiniteScroll"
      data-event={@event}
      data-has-more="true"
      data-root-margin={@root_margin}
      data-target={@target}
      class="flex items-center justify-center py-6 text-text-tertiary"
    >
      <svg class="animate-spin h-5 w-5" fill="none" viewBox="0 0 24 24" aria-hidden="true">
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.4 0 0 5.4 0 12h4z" />
      </svg>
      <span class="sr-only">Loading more…</span>
    </div>
    <p
      :if={not @has_more and @end_label}
      class="py-6 text-center text-xs text-text-tertiary"
    >
      {@end_label}
    </p>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def panel(assigns) do
    ~H"""
    <section
      class={["card-lift rounded-xl border border-border bg-panel shadow-card", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :hint, :string, default: nil
  attr :tone, :string, default: "default"
  attr :class, :any, default: nil
  attr :rest, :global

  def metric(assigns) do
    ~H"""
    <div
      class={["card-lift rounded-xl border border-border bg-panel px-4 py-3 shadow-card", @class]}
      {@rest}
    >
      <p class="text-eyebrow uppercase text-text-quaternary">
        {@label}
      </p>
      <p class={[
        "mt-1 font-serif text-2xl font-590 leading-8 tabular-nums",
        metric_tone(@tone)
      ]}>
        {@value}
      </p>
      <p :if={@hint} class="mt-1 truncate text-caption text-text-quaternary">{@hint}</p>
    </div>
    """
  end

  attr :title, :string, required: true
  attr :message, :string, default: nil
  attr :icon, :string, default: nil
  attr :class, :any, default: nil
  slot :icon_slot
  slot :actions

  def empty_state(assigns) do
    ~H"""
    <div class={["flex flex-col items-center justify-center px-6 py-16 text-center", @class]}>
      <div class="mb-4 flex h-12 w-12 items-center justify-center rounded-2xl border border-brand/20 bg-brand/10 text-text-tertiary shadow-[0_0_24px_rgba(217,119,87,0.12)]">
        <%= if @icon_slot != [] || @icon do %>
          {render_slot(@icon_slot)}
        <% else %>
          <.spark class="h-5 w-5 text-brand" />
        <% end %>
      </div>
      <p class="text-sm font-590 text-text-primary">{@title}</p>
      <p :if={@message} class="mt-1 max-w-md text-sm leading-5 text-text-tertiary">
        {@message}
      </p>
      <div :if={@actions != []} class="mt-4 flex flex-wrap justify-center gap-2">
        {render_slot(@actions)}
      </div>
    </div>
    """
  end

  attr :icon, :string, required: true

  def empty_state_icon(assigns) do
    ~H"""
    <%= case @icon do %>
      <% "search" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
          />
        </svg>
      <% "agent" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M17 20h5v-2a3 3 0 00-5.356-1.857M17 20H7m10 0v-2c0-.656-.126-1.283-.356-1.857M7 20H2v-2a3 3 0 015.356-1.857M7 20v-2c0-.656.126-1.283.356-1.857m0 0a5.002 5.002 0 019.288 0M15 7a3 3 0 11-6 0 3 3 0 016 0zm6 3a2 2 0 11-4 0 2 2 0 014 0zM7 10a2 2 0 11-4 0 2 2 0 014 0z"
          />
        </svg>
      <% "issue" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-6 9l2 2 4-4"
          />
        </svg>
      <% "project" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
          />
        </svg>
      <% "goal" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M13 10V3L4 14h7v7l9-11h-7z"
          />
        </svg>
      <% "document" -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414A1 1 0 0119 9.414V19a2 2 0 01-2 2z"
          />
        </svg>
      <% _ -> %>
        <svg class="h-5 w-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M20 13V6a2 2 0 00-2-2H6a2 2 0 00-2 2v7m16 0v5a2 2 0 01-2 2H6a2 2 0 01-2-2v-5m16 0h-2.586a1 1 0 00-.707.293l-2.414 2.414a1 1 0 01-.707.293h-2.172a1 1 0 01-.707-.293l-2.414-2.414A1 1 0 006.586 13H4"
          />
        </svg>
    <% end %>
    """
  end

  attr :label, :string, default: "Actions"
  attr :align, :string, default: "right"
  attr :class, :any, default: nil
  attr :trigger_text, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def overflow_menu(assigns) do
    ~H"""
    <details class={["cympho-menu relative", @class]}>
      <summary
        class={[
          "flex h-8 cursor-pointer list-none items-center justify-center rounded-md text-text-quaternary transition-colors hover:bg-surface-hover hover:text-text-primary",
          if(@trigger_text, do: "gap-1.5 px-2.5 text-xs font-510", else: "w-8")
        ]}
        aria-label={@label}
        title={@label}
        {@rest}
      >
        <svg class="h-4 w-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 5h.01M12 12h.01M12 19h.01"
          />
        </svg>
        <%!-- The kebab glyph is already the affordance; simple mode drops the
             word beside it. `label` still supplies the accessible name. --%>
        <span :if={@trigger_text} class="ui-advanced-only">{@trigger_text}</span>
      </summary>
      <div class={[
        "cympho-menu-panel absolute z-30 mt-2 min-w-44 rounded-xl border border-border bg-panel p-1 shadow-dialog",
        menu_align(@align)
      ]}>
        {render_slot(@inner_block)}
      </div>
    </details>
    """
  end

  attr :navigate, :string, default: nil
  attr :type, :string, default: "button"
  attr :danger, :boolean, default: false
  attr :rest, :global
  slot :inner_block, required: true

  def menu_item(%{navigate: navigate} = assigns) when is_binary(navigate) do
    ~H"""
    <.link
      navigate={@navigate}
      class={[
        "flex w-full items-center rounded-md px-2.5 py-2 text-left text-sm transition-colors",
        if(@danger,
          do: "text-red-300 hover:bg-red-500/10",
          else: "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  def menu_item(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "flex w-full items-center rounded-md px-2.5 py-2 text-left text-sm transition-colors",
        if(@danger,
          do: "text-red-300 hover:bg-red-500/10",
          else: "text-text-secondary hover:bg-surface-hover hover:text-text-primary"
        )
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :wake, :any, required: true
  attr :agent, :any, default: nil
  attr :class, :any, default: nil

  @doc """
  Renders a small "⏱ Waiting on X · 3m" chip when an issue has an active
  pending wake. Color tone reflects staleness, matching the stale-nudge
  thresholds used by `Cympho.ReviewNudges.StaleScanner`
  (default T1 = 120 s, T2 = 600 s).

  The wake (and optionally its agent) must be pre-fetched by the caller —
  e.g. via `Cympho.Wakes.most_recent_pending_for_issues/1` — so this
  component never hits the DB.
  """
  def pending_wake_badge(%{wake: nil} = assigns) do
    ~H""
  end

  def pending_wake_badge(assigns) do
    assigns =
      assigns
      |> assign_new(:agent, fn -> Map.get(assigns.wake, :agent) end)
      |> assign(:age_seconds, wake_age_seconds(assigns.wake))

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10px] font-510 leading-none",
        pending_wake_tone(@age_seconds),
        @class
      ]}
      title={pending_wake_title(@wake, @agent, @age_seconds)}
    >
      <span aria-hidden="true">⏱</span>
      <%!-- On a full board every card repeats "Waiting on agent"; the clock
           glyph and the column already carry that. Simple keeps just the age,
           and `title` still spells the whole thing out on hover. --%>
      <span class="ui-advanced-only font-mono tabular-nums">
        {pending_wake_label(@wake, @agent, @age_seconds)}
      </span>
      <span class="ui-simple-only font-mono tabular-nums">
        {format_wake_age(@age_seconds)}
      </span>
    </span>
    """
  end

  defp wake_age_seconds(%{inserted_at: %DateTime{} = ts}),
    do: DateTime.diff(DateTime.utc_now(), ts, :second)

  defp wake_age_seconds(_), do: 0

  defp pending_wake_tone(age) do
    cond do
      age >= 600 -> "border-brand/35 bg-brand/10 text-brand"
      age >= 120 -> "border-amber-500/35 bg-amber-500/10 text-amber-300"
      true -> "border-border bg-surface/60 text-text-tertiary"
    end
  end

  defp pending_wake_label(_wake, agent, age) do
    target = wake_target_label(agent)
    "Waiting on #{target} · #{format_wake_age(age)}"
  end

  defp pending_wake_title(wake, agent, age) do
    target = wake_target_label(agent)
    reason = (wake && wake.reason) || "wake"
    "#{reason}: waiting on #{target} for #{format_wake_age(age)}"
  end

  defp wake_target_label(%{name: name}) when is_binary(name) and name != "", do: name
  defp wake_target_label(_), do: "agent"

  defp format_wake_age(seconds) when seconds < 60, do: "#{max(seconds, 0)}s"
  defp format_wake_age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp format_wake_age(seconds), do: "#{div(seconds, 3600)}h"

  attr :navigate, :string, required: true
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def app_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["text-text-secondary hover:text-text-primary transition-colors", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :for, :any, required: true
  attr :as, :any, default: :global
  attr :rest, :global, include: ~w(method action)
  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <form {@rest}>
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="form-actions">
        {render_slot(@actions)}
      </div>
    </form>
    """
  end

  attr :field, :any, default: nil
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rows, :integer, default: nil
  attr :options, :list, default: nil
  attr :step, :string, default: nil
  attr :max, :string, default: nil
  attr :min, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :phx_change, :string, default: nil
  attr :id, :string, default: nil
  # `autocomplete` is not one of Phoenix's default global attributes, but form
  # fields need it to stop browsers autofilling credentials into unrelated pairs
  # of text+password inputs.
  attr :rest, :global, include: ~w(autocomplete)

  def input(assigns) do
    assigns = assign(assigns, :errors, input_errors(assigns.field))
    assigns = assign(assigns, :error_id, input_error_id(assigns.field, assigns.name, assigns.id))
    assigns = assign(assigns, :has_errors, assigns.errors != [])

    ~H"""
    <div class="space-y-1.5">
      <label
        :if={@label && @type != "checkbox"}
        for={input_id(@field, @id)}
        class="block text-xs font-510 text-text-secondary"
      >
        {@label}
      </label>
      <%!-- A checkbox needs its own branch: the generic input below is styled
           `w-full … px-3.5 py-2`, which stretched every checkbox into a
           full-width box floating under a block label. Here the box stays 16px
           and the label sits beside it, inside the same <label> so the text is
           part of the hit target. --%>
      <label :if={@type == "checkbox"} class="flex items-center gap-2">
        <input type="hidden" name={input_name(@field, @name)} value="false" />
        <input
          id={input_id(@field, @id)}
          type="checkbox"
          name={input_name(@field, @name)}
          value="true"
          checked={checked?(input_value(@field, @value))}
          required={@required}
          disabled={@disabled}
          aria-describedby={@has_errors && @error_id}
          aria-invalid={@has_errors}
          class="h-4 w-4 shrink-0 rounded border-border bg-canvas text-brand focus:ring-2 focus:ring-brand/40"
          {@rest}
        />
        <span :if={@label} class="text-sm text-text-primary">{@label}</span>
      </label>
      <textarea
        :if={@type == "textarea"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        rows={@rows}
        aria-describedby={@has_errors && @error_id}
        aria-invalid={@has_errors}
        class={[
          "w-full bg-surface border rounded-xl px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 transition duration-150",
          input_border_class(@errors)
        ]}
        {@rest}
      ><%= input_value(@field, @value) %></textarea>
      <.select_menu
        :if={@type == "select"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        options={select_options(@options)}
        disabled={@disabled}
        invalid={@has_errors}
        {@rest}
      />
      <.date_picker
        :if={@type == "date"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        disabled={@disabled}
        required={@required}
        invalid={@has_errors}
        min={@min}
        max={@max}
        {@rest}
      />
      <.time_picker
        :if={@type == "time"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        disabled={@disabled}
        required={@required}
        invalid={@has_errors}
        {@rest}
      />
      <.datetime_picker
        :if={@type == "datetime-local"}
        id={input_id(@field, @id)}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        disabled={@disabled}
        required={@required}
        invalid={@has_errors}
        min={@min}
        max={@max}
        {@rest}
      />
      <input
        :if={@type not in ["textarea", "select", "date", "time", "datetime-local", "checkbox"]}
        id={input_id(@field, @id)}
        type={@type}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        required={@required}
        disabled={@disabled}
        aria-describedby={@has_errors && @error_id}
        aria-invalid={@has_errors}
        class={[
          "w-full bg-surface border rounded-xl px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 transition duration-150",
          input_border_class(@errors)
        ]}
        {@rest}
      />
      <p
        :if={@has_errors}
        id={@error_id}
        class="flex items-center gap-1 text-xs text-error"
        aria-live="polite"
      >
        <span class="hero-exclamation-circle-mini h-3.5 w-3.5 shrink-0" aria-hidden="true"></span>
        {Enum.at(@errors, 0)}
      </p>
    </div>
    """
  end

  attr :type, :string, default: "submit"
  attr :variant, :string, default: nil
  attr :size, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      disabled={@disabled}
      class={[
        "inline-flex items-center justify-center gap-2 font-medium transition-colors rounded-button btn-press",
        button_variant(@variant),
        button_size(@size),
        @class,
        @disabled && "cursor-not-allowed opacity-50 saturate-50"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global

  @doc """
  Labeled form select — a thin wrapper around `select_menu/1` so existing
  call sites keep working while gaining the styled, theme-matched dropdown.
  """
  def select(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <%!-- The visible <label> cannot use for/id here: the control is a button,
           not the (aria-hidden) native select, so the name is passed down. --%>
      <label class="block text-xs font-510 text-text-secondary">{@label}</label>
      <.select_menu name={@name} value={@value} options={@options} label={@label} {@rest} />
    </div>
    """
  end

  attr :name, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, required: true, doc: "[{label, value}] | [%{label, value|id}] | [value]"
  attr :placeholder, :string, default: "Select…"
  attr :id, :string, default: nil
  attr :disabled, :boolean, default: false
  attr :invalid, :boolean, default: false
  attr :class, :any, default: nil

  attr :label, :string,
    default: nil,
    doc: "names the control for assistive tech; without it the trigger announces only its value"

  attr :rest, :global

  @doc """
  Styled, theme-matched replacement for a native `<select>`. Backed by a hidden
  input (so it posts with plain forms) and a document-delegated JS controller
  (assets/js/app.js) that handles open/close, keyboard nav and type-ahead, and
  dispatches native `input`/`change` events so LiveView `phx-change` forms react.
  """
  def select_menu(assigns) do
    options = normalize_select_options(assigns.options)
    value = if is_nil(assigns.value), do: nil, else: to_string(assigns.value)

    assigns =
      assigns
      |> assign(:options, options)
      |> assign(:value, value)
      |> assign(:selected_label, select_menu_label(options, value))

    ~H"""
    <div data-select-menu data-disabled={to_string(@disabled)} class={["relative", @class]}>
      <%!-- Real <select> is the value vehicle: it posts with the form and is
            LiveViewTest drivable, and the document-delegated JS in app.js mirrors
            picks from the styled popover below back onto it. It is aria-hidden and
            out of the tab order, so it is NOT what assistive tech or the keyboard
            uses — the trigger button below carries that role, which is why the
            button needs an explicit name. --%>
      <select
        id={@id}
        name={@name}
        data-select-native
        disabled={@disabled}
        tabindex="-1"
        aria-hidden="true"
        class="sr-only"
        {@rest}
      >
        <option :for={{label, val} <- @options} value={val} selected={val == @value}>{label}</option>
      </select>
      <button
        type="button"
        data-select-trigger
        disabled={@disabled}
        title={@label}
        aria-label={@label}
        aria-haspopup="listbox"
        aria-expanded="false"
        class={[
          "flex w-full items-center gap-2 h-9 px-2.5 rounded-input text-left",
          "bg-surface border text-caption text-ink transition duration-150",
          "focus:outline-none focus:ring-2 disabled:opacity-50 disabled:cursor-not-allowed",
          (@invalid && "border-error focus:ring-red-500/40 focus:border-error") ||
            "border-hairline hover:border-hairline-strong focus:ring-primary/30 focus:border-primary focus:shadow-[0_0_16px_-4px_rgb(var(--color-primary-rgb)/0.35)]"
        ]}
      >
        <span
          data-select-display
          class={["min-w-0 flex-1 truncate", is_nil(@selected_label) && "text-ink-tertiary"]}
        >
          {@selected_label || @placeholder}
        </span>
        <span class="hero-chevron-down-mini w-3.5 h-3.5 shrink-0 text-ink-tertiary transition-transform duration-200 [[aria-expanded=true]_&]:rotate-180" />
      </button>

      <div
        data-select-popover
        role="listbox"
        class={[
          "hidden absolute left-0 top-full z-50 w-full min-w-[9rem]",
          "cympho-menu-panel rounded-lg bg-surface-2 border border-hairline shadow-elevated overflow-hidden"
        ]}
      >
        <ul data-select-list class="max-h-60 overflow-y-auto py-1">
          <li
            :for={{label, val} <- @options}
            data-select-option
            data-select-option-value={val}
            data-select-option-label={label}
            data-select-selected={to_string(val == @value)}
            role="option"
            aria-selected={to_string(val == @value)}
            class={[
              "flex items-center gap-2 mx-1 px-2.5 h-8 rounded-sm cursor-pointer select-none",
              "text-caption text-ink transition-colors duration-100",
              "hover:bg-surface-3 data-[select-active=true]:bg-surface-3",
              "data-[select-selected=true]:bg-brand/[0.06]"
            ]}
          >
            <span class="min-w-0 flex-1 truncate">{label}</span>
            <span
              data-select-check
              class={["hero-check-mini w-4 h-4 shrink-0 text-primary", val != @value && "invisible"]}
            />
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp normalize_select_options(options) do
    Enum.map(options, fn
      {label, value} -> {to_string(label), to_string(value)}
      %{label: label, value: value} -> {to_string(label), to_string(value)}
      %{label: label, id: id} -> {to_string(label), to_string(id)}
      value -> {to_string(value), to_string(value)}
    end)
  end

  defp select_menu_label(_options, nil), do: nil

  defp select_menu_label(options, value) do
    case Enum.find(options, fn {_label, val} -> val == value end) do
      {label, _val} -> label
      _ -> nil
    end
  end

  defp input_name(_field, name) when is_binary(name), do: name
  defp input_name(%{name: name}, _name), do: name
  defp input_name(_, _), do: nil

  defp input_value(_field, value) when not is_nil(value), do: value
  defp input_value(%{value: value}, _value), do: value
  defp input_value(_, _), do: nil

  defp select_options(nil), do: []

  defp select_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {value, value}
    end)
  end

  defp button_variant("primary"),
    do: "cta-glow bg-brand text-on-primary font-590 hover:bg-accent-hover"

  defp button_variant("secondary"),
    do:
      "bg-button text-text-primary border border-border shadow-[inset_0_1px_0_0_var(--shadow-inset-highlight)] hover:bg-button-hover hover:border-hairline-strong"

  defp button_variant("ghost"),
    do: "text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp button_variant("danger"),
    do:
      "bg-error text-canvas font-590 shadow-[inset_0_1px_0_0_rgba(255,255,255,0.12)] hover:bg-red-600 hover:shadow-[0_0_20px_-4px_rgb(var(--color-error-rgb)/0.45)]"

  defp button_variant(_),
    do:
      "bg-button text-text-primary border border-border shadow-[inset_0_1px_0_0_var(--shadow-inset-highlight)] hover:bg-button-hover hover:border-hairline-strong"

  defp button_size("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size("lg"), do: "px-6 py-3 text-base"
  defp button_size(_), do: "px-4 py-2 text-sm"

  attr :field, :any, required: true

  def error(assigns) do
    assigns = assign(assigns, :errors, input_errors(assigns.field))

    ~H"""
    <div :for={error <- @errors} class="text-xs text-error mt-1">
      {error}
    </div>
    """
  end

  defp input_errors(nil), do: []
  defp input_errors(%{errors: errors}), do: Enum.map(errors, &format_input_error/1)
  defp input_errors(_), do: []

  defp format_input_error({message, opts}) when is_binary(message) and is_list(opts) do
    Enum.reduce(opts, message, fn
      {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end

  defp format_input_error(message) when is_binary(message), do: message
  defp format_input_error(message), do: inspect(message)

  defp checked?(true), do: true
  defp checked?("true"), do: true
  defp checked?(_), do: false

  defp input_border_class([]),
    do:
      "border-border hover:border-hairline-strong focus:ring-brand/25 focus:border-brand focus:shadow-[0_0_16px_-4px_rgb(var(--color-primary-rgb)/0.35)]"

  defp input_border_class(_),
    do: "border-red-500/60 focus:ring-red-500/25 focus:border-error"

  defp input_error_id(_field, _name, id) when is_binary(id), do: "#{id}-error"
  defp input_error_id(field, name, _id), do: "input-error-#{input_name(field, name) || "unknown"}"

  defp input_id(%{id: id}, _name), do: id
  defp input_id(_field, id) when is_binary(id), do: id
  defp input_id(_, _), do: nil

  defp page_size("form"), do: "max-w-3xl"
  defp page_size("content"), do: "max-w-6xl"
  defp page_size("wide"), do: "max-w-7xl"
  defp page_size("full"), do: "max-w-none"
  defp page_size(_), do: "max-w-7xl"

  defp metric_tone("brand"), do: "text-brand"
  defp metric_tone("success"), do: "text-success"
  defp metric_tone("warning"), do: "text-amber-300"
  defp metric_tone("danger"), do: "text-brand"
  defp metric_tone(_), do: "text-text-primary"

  defp menu_align("left"), do: "left-0"
  defp menu_align(_), do: "right-0"
end
