defmodule CymphoWeb.Components.R3 do
  @moduledoc """
  Shared function components of the r3 "Paper & Ink" design.

  Markup and class names reproduce the approved mockups' builders
  (`ui-redesign/v5/notes/r3-src/build.py`), so `assets/css/r3.css` styles them
  unchanged. Copy is always passed in, never written here, except the fixed
  words of the shell tools (Search, New task, Settings) and the own-answer row.

  The page's one primary (`primary_pill/1`) lives only on the resolution card
  (`ink_card/1`), inside `ink_foot/1`.
  """
  use Phoenix.Component

  # The icon sprite (build.py `_SYMBOLS` and `_EXTRA`): rendered once by the root layout.
  @symbols ~S|<symbol id="i-home" viewBox="0 0 20 20"><path d="M3.5 8.75 10 3.5l6.5 5.25v6.75a1 1 0 0 1-1 1H12v-4.25H8v4.25H4.5a1 1 0 0 1-1-1z"/></symbol>
<symbol id="i-inbox" viewBox="0 0 20 20"><path d="M3.25 11.25 5.1 4.6a1 1 0 0 1 .96-.73h7.88a1 1 0 0 1 .96.73l1.85 6.65v3.9a1 1 0 0 1-1 1H4.25a1 1 0 0 1-1-1z"/><path d="M3.25 11.25h3.6l.9 1.9h4.5l.9-1.9h3.6"/></symbol>
<symbol id="i-tasks" viewBox="0 0 20 20"><rect x="3.5" y="3.5" width="13" height="13" rx="3.25"/><path d="m7 10.1 2.1 2.1L13.2 8"/></symbol>
<symbol id="i-team" viewBox="0 0 20 20"><circle cx="8" cy="7" r="2.75"/><path d="M3.1 16c.6-2.5 2.5-3.9 4.9-3.9s4.3 1.4 4.9 3.9"/><path d="M13.4 4.5a2.6 2.6 0 0 1 0 5M15 12.5c1.15.55 1.95 1.6 2.3 3.2"/></symbol>
<symbol id="i-spend" viewBox="0 0 20 20"><ellipse cx="10" cy="5.75" rx="5.75" ry="2.5"/><path d="M4.25 5.75v4.25c0 1.4 2.6 2.5 5.75 2.5s5.75-1.1 5.75-2.5V5.75"/><path d="M4.25 10v4.25c0 1.4 2.6 2.5 5.75 2.5s5.75-1.1 5.75-2.5V10"/></symbol>
<symbol id="i-settings" viewBox="0 0 20 20"><path d="M3.5 6.25h7.25M14.75 6.25h1.75M3.5 13.75h1.75M9.25 13.75h7.25"/><circle cx="12.75" cy="6.25" r="2"/><circle cx="7.25" cy="13.75" r="2"/></symbol>
<symbol id="i-search" viewBox="0 0 20 20"><circle cx="9" cy="9" r="5.25"/><path d="m13 13 3.5 3.5"/></symbol>
<symbol id="i-plus" viewBox="0 0 20 20"><path d="M10 4.75v10.5M4.75 10h10.5"/></symbol>
<symbol id="i-chev-down" viewBox="0 0 20 20"><path d="m6 8 4 4 4-4"/></symbol>
<symbol id="i-chev-left" viewBox="0 0 20 20"><path d="m12 5-5 5 5 5"/></symbol>
<symbol id="i-chev-updown" viewBox="0 0 20 20"><path d="m7 7.75 3-3 3 3M7 12.25l3 3 3-3"/></symbol>
<symbol id="i-arrow-right" viewBox="0 0 20 20"><path d="M4.75 10h10.5M10.75 5.5 15.25 10l-4.5 4.5"/></symbol>
<symbol id="i-arrow-left" viewBox="0 0 20 20"><path d="M15.25 10H4.75M9.25 5.5 4.75 10l4.5 4.5"/></symbol>
<symbol id="i-external" viewBox="0 0 20 20"><path d="M7 13 13.25 6.75M8 6.75h5.25V12"/></symbol>
<symbol id="i-question" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><path d="M8 8.1a2 2 0 1 1 2.85 1.8c-.55.27-.85.75-.85 1.35v.3"/><path d="M10 14h.01" stroke-width="2"/></symbol>
<symbol id="i-doc-check" viewBox="0 0 20 20"><path d="M5.5 3.25h5.75l3.25 3.25v10.25h-9z"/><path d="M11.25 3.25V6.5h3.25"/><path d="m7.75 12 1.6 1.6 2.9-3.1"/></symbol>
<symbol id="i-shield" viewBox="0 0 20 20"><path d="M10 2.75 4.25 5v4.4c0 3.5 2.45 6.2 5.75 7.6 3.3-1.4 5.75-4.1 5.75-7.6V5z"/><path d="m7.6 10 1.65 1.65 3.15-3.4"/></symbol>
<symbol id="i-pencil" viewBox="0 0 20 20"><path d="M12.6 4.6a1.6 1.6 0 0 1 2.3 2.3l-8 8-3.15.85.85-3.15z"/><path d="m11.4 5.8 2.3 2.3"/></symbol>
<symbol id="i-check" viewBox="0 0 20 20"><path d="m5.75 10.25 2.75 2.75 5.75-6"/></symbol>
<symbol id="g-work" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.5" stroke-opacity=".28"/><path d="M6 1.5A4.5 4.5 0 0 1 10.5 6"/></symbol>
<symbol id="g-wait" viewBox="0 0 12 12"><circle cx="6" cy="6" r="3.75" fill="currentColor" stroke="none"/></symbol>
<symbol id="g-stop" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.5"/><path d="m4.3 4.3 3.4 3.4M7.7 4.3 4.3 7.7"/></symbol>
<symbol id="g-done" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.5"/><path d="m4.1 6.1 1.35 1.35L8 4.8"/></symbol>
<symbol id="g-idle" viewBox="0 0 12 12"><circle cx="6" cy="6" r="4.5"/></symbol>
<symbol id="i-stop" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><path d="m7.5 7.5 5 5M12.5 7.5l-5 5"/></symbol>
<symbol id="i-halt" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><rect x="7.6" y="7.6" width="4.8" height="4.8" rx="1"/></symbol>
<symbol id="i-filter" viewBox="0 0 20 20"><path d="M3.75 6h12.5M6 10h8M8.25 14h3.5"/></symbol>
<symbol id="i-low" viewBox="0 0 20 20"><rect x="2.75" y="6.25" width="12.5" height="7.5" rx="2"/><path d="M17.25 8.75v2.5M6 8.9v2.2"/></symbol>
<symbol id="i-pause" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><path d="M8.25 7.6v4.8M11.75 7.6v4.8"/></symbol>
<symbol id="i-alert" viewBox="0 0 20 20"><circle cx="10" cy="10" r="7"/><path d="M10 6.6v4.1"/><path d="M10 13.4h.01" stroke-width="2"/></symbol>
<symbol id="i-term" viewBox="0 0 20 20"><rect x="3" y="4.25" width="14" height="11.5" rx="2.5"/><path d="m6.6 8.4 1.9 1.7-1.9 1.7M10.6 11.9h3"/></symbol>
<symbol id="i-chev-right" viewBox="0 0 20 20"><path d="m8 5 5 5-5 5"/></symbol>|

  # File glyphs are inlined, not <use>d: their token colours come from .cy-r3 selectors,
  # which cannot reach a <use> shadow tree (build.py F_DOC / F_CODE).
  @file_doc ~S|<svg class="file" viewBox="0 0 34 42" aria-hidden="true"><path class="fp" d="M4 1.5h17.5L31.5 11.5V38a2.5 2.5 0 0 1-2.5 2.5H4A2.5 2.5 0 0 1 1.5 38V4A2.5 2.5 0 0 1 4 1.5z" stroke-width="1.2"/><path class="ff" d="M21.5 1.5v7.5a2.5 2.5 0 0 0 2.5 2.5h7.5" stroke-width="1.2"/><path class="fm" d="M8 19h12M8 24h17M8 29h14" stroke-width="2" stroke-linecap="round"/></svg>|
  @file_code ~S|<svg class="file" viewBox="0 0 34 42" aria-hidden="true"><path class="fp" d="M4 1.5h17.5L31.5 11.5V38a2.5 2.5 0 0 1-2.5 2.5H4A2.5 2.5 0 0 1 1.5 38V4A2.5 2.5 0 0 1 4 1.5z" stroke-width="1.2"/><path class="ff" d="M21.5 1.5v7.5a2.5 2.5 0 0 0 2.5 2.5h7.5" stroke-width="1.2"/><path class="fm" d="m12.5 21-4 4 4 4M20.5 21l4 4-4 4M17.75 19.5l-2 11" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>|

  @status %{
    working: {"g-work", "c-work"},
    waiting: {"g-wait", "c-wait"},
    stopped: {"g-stop", "c-stop"},
    done: {"g-done", "c-done"},
    idle: {"g-idle", "c-idle"}
  }

  @ticks 60

  ## ── Icons and status ──────────────────────────────────────────

  @doc "The inline icon sprite every `r3_icon/1` and `status_glyph/1` points at."
  def r3_sprite(assigns) do
    assigns = assign(assigns, :symbols, Phoenix.HTML.raw(@symbols))

    ~H"""
    <svg class="sprite" aria-hidden="true" focusable="false">{@symbols}</svg>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: "ico s16"

  def r3_icon(assigns) do
    ~H"""
    <svg class={@class} aria-hidden="true"><use href={"#" <> @name} /></svg>
    """
  end

  attr :kind, :atom, required: true, values: [:working, :waiting, :stopped, :done, :idle]
  attr :big, :boolean, default: false
  attr :color, :boolean, default: true, doc: "false leaves the colour to the container"

  @doc "Status shape (spec §1.5). Working spins; every other state is still."
  def status_glyph(assigns) do
    {symbol, colour} = Map.fetch!(@status, assigns.kind)
    assigns = assign(assigns, symbol: symbol, colour: colour)

    ~H"""
    <svg
      class={["g", @big && "lg", @color && @colour, @kind == :working && "spin"]}
      viewBox="0 0 12 12"
      aria-hidden="true"
    >
      <use href={"#" <> @symbol} />
    </svg>
    """
  end

  attr :kind, :atom, required: true, values: [:working, :waiting, :stopped, :done, :idle]
  attr :word, :string, required: true
  attr :big, :boolean, default: false

  @doc "Glyph + word; the word takes its colour from the container."
  def status_word(assigns) do
    ~H"""
    <.status_glyph kind={@kind} big={@big} />{@word}
    """
  end

  ## ── Page frame ────────────────────────────────────────────────

  attr :page, :string, required: true, doc: "data-page, the hook for page CSS"
  attr :kind, :atom, default: :root, values: [:root, :deep]
  attr :title, :string, default: nil, doc: "root pages: the H1"
  attr :parent, :any, default: nil, doc: "deep pages: {href, label} of the breadcrumb parent"
  attr :current, :string, default: nil, doc: "deep pages: the last breadcrumb item"
  attr :current_mono, :boolean, default: false
  attr :from, :any, default: nil, doc: "{path, label} from CymphoWeb.UserAuth.safe_from/1"
  attr :tray_class, :string, default: nil
  attr :rest, :global

  slot :aside, doc: "root pages: the two-tone aside after the H1"
  slot :header_end, doc: "root pages: controls at the header's end (a view switch, a Hire pill)"
  slot :head, doc: "deep pages: the page's own header block (H1, chips) above the tray"
  slot :inner_block, required: true

  @doc """
  The page frame: a sticky context header and the tray. A root page's header is
  its H1; a deep page's header is the breadcrumb, "Back to …" when it was opened
  from somewhere other than its parent (N5), and the phone tools.
  """
  def page_frame(assigns) do
    assigns = assign(assigns, :back, back_link(assigns.from, assigns.parent))

    ~H"""
    <div class="frame" data-page={@page} {@rest}>
      <header :if={@kind == :root} class="ctx" data-ctx="root">
        <div class="ctx-title">
          <h1 class="h1">{@title}</h1>
          <p :if={@aside != []} class="h1-aside">{render_slot(@aside)}</p>
        </div>
        <div :if={@header_end != []} class="ctx-end">{render_slot(@header_end)}</div>
      </header>
      <header :if={@kind == :deep} class="ctx" data-ctx="deep">
        <.link :if={@back} class="from" navigate={elem(@back, 0)}>
          <.r3_icon name="i-chev-left" />{elem(@back, 1)}
        </.link>
        <nav class="crumb" aria-label="Breadcrumb">
          <ol>
            <li>
              <.link class="back" navigate={elem(@parent, 0)}>
                <.r3_icon name="i-chev-left" />{elem(@parent, 1)}
              </.link>
              <span class="sep" aria-hidden="true">›</span>
            </li>
            <li><span class={@current_mono && "mono"} aria-current="page">{@current}</span></li>
          </ol>
        </nav>
        <.link :if={@back} class="ret" navigate={elem(@back, 0)}>
          <.r3_icon name="i-arrow-left" /><span>Back to {elem(@back, 1)}</span>
        </.link>
        <.ctx_tools />
      </header>
      {render_slot(@head)}
      <div class={["tray", @tray_class]}>{render_slot(@inner_block)}</div>
    </div>
    """
  end

  defp back_link({path, _label} = from, {parent_path, _}) when path != parent_path, do: from
  defp back_link({_path, _label} = from, nil), do: from
  defp back_link(_from, _parent), do: nil

  # Deep pages have no phone top bar, so their header keeps Search, New task and Settings.
  defp ctx_tools(assigns) do
    ~H"""
    <div class="ctx-tools">
      <.link class="ib" navigate="/search" aria-label="Search">
        <.r3_icon name="i-search" class="ico" />
      </.link>
      <a class="ib new" href="/issues/new" data-quick-create-trigger aria-label="New task">
        <.r3_icon name="i-plus" class="ico" />
      </a>
      <a class="ib" href="/settings" aria-label="Settings">
        <.r3_icon name="i-settings" class="ico" />
      </a>
    </div>
    """
  end

  ## ── The Next step pair ────────────────────────────────────────

  attr :id, :string, default: "ns-", doc: "id prefix; the problem card's title id is <id>t"
  slot :problem, required: true
  slot :resolution

  @doc "The Next step: the problem card and its resolution card. A lone problem spans both columns."
  def next_step(assigns) do
    ~H"""
    <section class="next" aria-labelledby={@id <> "t"}>
      {render_slot(@problem)}{render_slot(@resolution)}
    </section>
    """
  end

  attr :title, :string, required: true
  attr :title_id, :string, default: "ns-t"
  attr :class, :any, default: nil
  slot :eyebrow, required: true
  slot :inner_block
  slot :foot, doc: "the card's footer line (.pf): the object link and its context"

  def problem_card(assigns) do
    ~H"""
    <article class={["paper", @class]}>
      <p class="eyebrow">{render_slot(@eyebrow)}</p>
      <h2 class="nt" id={@title_id}>{@title}</h2>
      {render_slot(@inner_block)}
      <div :if={@foot != []} class="pf">{render_slot(@foot)}</div>
    </article>
    """
  end

  attr :heading, :string, default: nil
  attr :heading_id, :string, default: "ns-i"

  attr :form, :string,
    default: nil,
    doc: "renders the card as this form (its aria-label), without a heading"

  attr :rest, :global, include: ~w(action method)
  slot :inner_block, required: true

  @doc "The resolution card: the inverse surface holding what the one primary does."
  def ink_card(%{form: form} = assigns) when is_binary(form) do
    ~H"""
    <form class="ink" aria-label={@form} {@rest}>
      {render_slot(@inner_block)}
    </form>
    """
  end

  def ink_card(assigns) do
    ~H"""
    <article class="ink" aria-labelledby={@heading && @heading_id} {@rest}>
      <h3 :if={@heading} class="ink-h" id={@heading_id}>{@heading}</h3>
      {render_slot(@inner_block)}
    </article>
    """
  end

  attr :rows, :list, required: true, doc: "[{status kind, text}], one per effect"

  def consequences(assigns) do
    ~H"""
    <ul class="conseq">
      <li :for={{kind, text} <- @rows}>
        <.status_glyph kind={kind} big color={false} /><span>{text}</span>
      </li>
    </ul>
    """
  end

  slot :inner_block, required: true

  def ink_note(assigns) do
    ~H"""
    <p class="ink-note">{render_slot(@inner_block)}</p>
    """
  end

  attr :verb, :string, default: nil, doc: "the ⌘↵ hint's verb; nil hides the hint"
  slot :secondary
  slot :primary, required: true

  @doc "The resolution card's footer: the ⌘↵ hint, one secondary, then the primary."
  def ink_foot(assigns) do
    ~H"""
    <div class="ink-f">
      <span :if={@verb} class="kh"><kbd>⌘</kbd><kbd>↵</kbd><span>to {@verb}</span></span>
      {render_slot(@secondary)}{render_slot(@primary)}
    </div>
    """
  end

  ## ── Buttons and links ─────────────────────────────────────────

  attr :type, :string, default: "button"
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value method)
  slot :inner_block, required: true

  @doc "The page's one primary (S2): a pill with a nested arrow nub. With a link it navigates (S7)."
  def primary_pill(assigns) do
    ~H"""
    <%= if link?(assigns) do %>
      <.link class="pw" navigate={@navigate} patch={@patch} href={@href} {@rest}>
        {render_slot(@inner_block)}<span class="nub"><.r3_icon name="i-arrow-right" /></span>
      </.link>
    <% else %>
      <button class="pw" type={@type} {@rest}>
        {render_slot(@inner_block)}<span class="nub"><.r3_icon name="i-arrow-right" /></span>
      </button>
    <% end %>
    """
  end

  attr :type, :string, default: "button"
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value method)
  slot :inner_block, required: true

  @doc "Secondary pill: every action that is not the page's one primary."
  def pill(assigns) do
    ~H"""
    <%= if link?(assigns) do %>
      <.link class="pl" navigate={@navigate} patch={@patch} href={@href} {@rest}>
        {render_slot(@inner_block)}
      </.link>
    <% else %>
      <button class="pl" type={@type} {@rest}>{render_slot(@inner_block)}</button>
    <% end %>
    """
  end

  attr :type, :string, default: "button"
  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :rest, :global, include: ~w(disabled form name value method)
  slot :inner_block, required: true

  @doc "Secondary action on the resolution card."
  def ghost_pill(assigns) do
    ~H"""
    <%= if link?(assigns) do %>
      <.link class="pd" navigate={@navigate} patch={@patch} href={@href} {@rest}>
        {render_slot(@inner_block)}
      </.link>
    <% else %>
      <button class="pd" type={@type} {@rest}>{render_slot(@inner_block)}</button>
    <% end %>
    """
  end

  attr :navigate, :string, default: nil
  attr :patch, :string, default: nil
  attr :href, :string, default: nil
  attr :arrow, :boolean, default: true
  attr :rest, :global
  slot :inner_block, required: true

  @doc "Tertiary text link (\"Open Inbox →\")."
  def text_link(assigns) do
    ~H"""
    <.link class="lnk" navigate={@navigate} patch={@patch} href={@href} {@rest}>
      {render_slot(@inner_block)}<.r3_icon :if={@arrow} name="i-arrow-right" />
    </.link>
    """
  end

  defp link?(assigns), do: Enum.any?([assigns.navigate, assigns.patch, assigns.href])

  attr :tone, :string,
    default: nil,
    doc: "\"st-wait\" tints it Waiting; \"ghost\" makes it a quiet disclosure"

  attr :rest, :global
  slot :inner_block, required: true

  def chip(assigns) do
    ~H"""
    <button class={["chip", @tone]} type="button" {@rest}>{render_slot(@inner_block)}</button>
    """
  end

  ## ── Answer options ────────────────────────────────────────────

  attr :name, :string, required: true
  attr :legend, :string, required: true
  attr :items, :list, required: true, doc: "[%{value, label, sub?, disabled?}], 2–4 options"
  attr :checked, :any, default: nil
  attr :own, :boolean, default: true, doc: "adds the \"Or write your own answer\" row"
  attr :describedby, :string, default: nil
  attr :class, :any, default: nil

  @doc """
  Numbered answer options as a native radio fieldset. Each radio sits right
  before its label, so the chosen row is styled with `:checked + .opt` (no
  `:has()`); the own-answer row reveals its text box (`own_response`) the same way.
  """
  def option_rows(assigns) do
    assigns = assign(assigns, :numbered, Enum.with_index(assigns.items, 1))

    ~H"""
    <fieldset class={["opts", @class]} aria-describedby={@describedby}>
      <legend>{@legend}</legend>
      <div :for={{item, n} <- @numbered} class="opt-w">
        <input
          class="opt-in"
          type="radio"
          id={"#{@name}-#{n}"}
          name={@name}
          value={item.value}
          checked={to_string(item.value) == to_string(@checked)}
          disabled={Map.get(item, :disabled, false)}
        />
        <label class="opt" for={"#{@name}-#{n}"}>
          <span class="on" aria-hidden="true">{n}</span><span class="ot"><%= if Map.get(item, :sub) do %><span class="ot-n">{item.label}</span><span class="ot-s">{item.sub}</span><% else %>{item.label}<% end %></span><span
            class="radio"
            aria-hidden="true"
          ></span>
        </label>
      </div>
      <div :if={@own} class="opt-w">
        <input
          class="opt-in"
          type="radio"
          id={"#{@name}-o"}
          name={@name}
          value="own"
          checked={@checked == "own"}
        />
        <label class="opt own" for={"#{@name}-o"}>
          <span class="on" aria-hidden="true"><.r3_icon name="i-pencil" /></span><span class="ot">Or write your own answer</span><span
            class="radio"
            aria-hidden="true"
          ></span>
        </label>
        <div class="own-box">
          <label class="sr" for={"#{@name}-own"}>Your own answer</label>
          <textarea id={"#{@name}-own"} name="own_response" rows="2"></textarea>
        </div>
      </div>
    </fieldset>
    """
  end

  ## ── Meters and runs ───────────────────────────────────────────

  attr :percent, :any, required: true, doc: "spend as a share of the limit, 0–100 (clamped)"
  attr :warn_percent, :integer, default: 80
  attr :class, :string, default: nil, doc: "\"ruler\", \"full\" …"
  slot :legend, doc: "replaces the default \"80%\" legend"

  @doc """
  The 60-tick meter: filled ticks for spend and the amber warning mark. It is
  decoration (aria-hidden); its value is text next to it.
  """
  def tick_meter(assigns) do
    fill = assigns.percent |> to_number() |> max(0) |> min(100)

    assigns =
      assigns
      |> assign(:ticks, @ticks)
      |> assign(:fill_style, fill_style(fill))

    ~H"""
    <div class={["tk", @class]} aria-hidden="true" data-ticks={@ticks}>
      <span
        class="tk-fill"
        style={@fill_style}
      >
      </span><span class="tk-warn" style={"left:#{@warn_percent}%"}></span>
    </div>
    <div class="tk-legend mono" aria-hidden="true">
      <%= if @legend != [] do %>
        {render_slot(@legend)}
      <% else %>
        <span class="w" style={"left:#{@warn_percent}%"}>{@warn_percent}%</span>
      <% end %>
    </div>
    """
  end

  # The fill's tick spacing is 100% / (60 × fill), which keeps one tick per sixtieth of the limit.
  defp fill_style(fill) when fill == 0, do: "width:0%"

  defp fill_style(fill) do
    "width:#{fmt(fill)}%;background-size:calc(100% / #{fmt(@ticks * fill / 100)}) 100%"
  end

  attr :runs, :list, required: true, doc: "[%{started_at, completed_at, status}]"
  attr :label, :string, required: true, doc: "the figure's accessible name"

  attr :axis_min, :integer,
    default: nil,
    doc: "minutes; the axis is at least the longest run shown"

  @doc "Runs as bars on one shared minute axis; failed and timed-out runs are hatched."
  def run_bars(assigns) do
    bars = Enum.map(assigns.runs, &run_bar/1)
    axis = Enum.max([assigns.axis_min || 0 | Enum.map(bars, & &1.minutes)])
    bars = Enum.map(bars, &Map.put(&1, :width, fmt(&1.minutes * 100 / max(axis, 1))))

    assigns = assign(assigns, bars: bars, axis: axis, half: fmt(axis / 2))

    ~H"""
    <figure class="rb" aria-label={@label}>
      <%= for bar <- @bars do %>
        <span class="rb-t mono">{bar.start}</span><span class="rb-track"><span
          class={["rb-bar", (bar.failed? && "hatch") || "solid"]}
          style={"width:#{bar.width}%;min-width:10px"}
        ></span></span><span class={["rb-v", !bar.failed? && "ok"]}>{bar.word}<span aria-hidden="true"> · </span><span class="mono">{bar.minutes} min</span></span>
      <% end %>
      <span></span><span class="rb-axis mono" aria-hidden="true"><span>0</span><span>{@half}</span><span>{@axis} min</span></span><span></span>
    </figure>
    """
  end

  defp run_bar(run) do
    started = Map.get(run, :started_at)
    ended = Map.get(run, :completed_at) || DateTime.utc_now()
    seconds = if started, do: max(DateTime.diff(ended, started), 0), else: 0
    status = run |> Map.get(:status) |> to_string()

    %{
      start: if(started, do: Calendar.strftime(started, "%H:%M"), else: ""),
      minutes: max(div(seconds + 59, 60), 1),
      failed?: status in ~w(failed timed_out),
      word: run_word(status)
    }
  end

  defp run_word("failed"), do: "Failed"
  defp run_word("timed_out"), do: "Timed out"
  defp run_word("completed"), do: "Finished"
  defp run_word("running"), do: "Working"
  defp run_word("cancelled"), do: "Cancelled"
  defp run_word(other), do: other |> String.replace("_", " ") |> String.capitalize()

  attr :state, :atom, default: :waiting, values: [:working, :waiting, :idle]
  slot :inner_block, required: true
  slot :sub

  @doc "The Now capsule: a dot field per state; only Working loops."
  def now_capsule(assigns) do
    ~H"""
    <div class={["now", to_string(@state)]}>
      <span class="dots" aria-hidden="true"></span>
      <p class="now-t">
        <span>{render_slot(@inner_block)}</span><small :if={@sub != []}>{render_slot(@sub)}</small>
      </p>
    </div>
    """
  end

  ## ── Objects, lists and cards ──────────────────────────────────

  attr :kind, :atom, default: :doc, values: [:doc, :code]
  attr :title, :string, required: true
  attr :href, :string, required: true
  attr :sub, :string, default: nil
  attr :go, :string, default: "Open"
  attr :external, :boolean, default: false
  slot :sub_line, doc: "replaces `sub` when it needs markup"

  def object_tile(assigns) do
    assigns =
      assign(
        assigns,
        :file,
        Phoenix.HTML.raw(if(assigns.kind == :code, do: @file_code, else: @file_doc))
      )

    ~H"""
    <div class="objt">
      {@file}
      <div class="objt-m">
        <.link class="objt-t" href={@href}>{@title}</.link>
        <span :if={@sub_line != []} class="objt-s">{render_slot(@sub_line)}</span>
        <span :if={@sub_line == [] && @sub} class="objt-s">{@sub}</span>
      </div>
      <span class="go" aria-hidden="true">
        {@go}<.r3_icon :if={@external} name="i-external" class="ico s14" />
      </span>
    </div>
    """
  end

  attr :tight, :boolean, default: false
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :term, :string, required: true
  end

  @doc "Property list (term, value)."
  def kv_list(assigns) do
    ~H"""
    <dl class={["kv", @tight && "tight", @class]}>
      <%= for item <- @item do %>
        <dt>{item.term}</dt>
        <dd>{render_slot(item)}</dd>
      <% end %>
    </dl>
    """
  end

  attr :label, :string, required: true
  attr :class, :any, default: nil

  slot :item, required: true do
    attr :patch, :string
    attr :navigate, :string
    attr :href, :string
    attr :current, :boolean
  end

  @doc "Segmented links (tabs, filters): the current one is lifted and carries the orange dot."
  def segmented(assigns) do
    ~H"""
    <nav class={["seg", @class]} aria-label={@label}>
      <.link
        :for={item <- @item}
        patch={item[:patch]}
        navigate={item[:navigate]}
        href={item[:href]}
        aria-current={item[:current] && "page"}
      >
        {render_slot(item)}
      </.link>
    </nav>
    """
  end

  attr :id, :string, required: true, doc: "the heading's id; labels the section"
  attr :title, :string, required: true
  attr :band, :boolean, default: true, doc: "the filled header row"
  attr :class, :any, default: nil
  slot :header_end
  slot :inner_block

  def band_card(assigns) do
    ~H"""
    <section class={["card", @class]} aria-labelledby={@id}>
      <div class={["card-h", @band && "band"]}>
        <h2 class="h2" id={@id}>{@title}</h2>
        {render_slot(@header_end)}
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :id, :string, required: true, doc: "the title's id; the meta line is <id>m"
  attr :kind, :atom, default: :neutral, values: [:question, :problem, :neutral]
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :verb, :string, required: true
  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  slot :inner_block, doc: "the meta line: at most 4 parts"

  @doc "Decision row: kind tile · title · meta · one secondary verb that covers the row."
  def needs_row(assigns) do
    ~H"""
    <li class="row">
      <span class={["kt", row_kind(@kind)]}><.r3_icon name={@icon} /></span>
      <span class="row-main">
        <span class="rt" id={@id}>{@title}</span>
        <span class="rm" id={@id <> "m"}>{render_slot(@inner_block)}</span>
      </span>
      <.link class="pl go" navigate={@navigate} href={@href} aria-describedby={"#{@id} #{@id}m"}>
        {@verb}
      </.link>
    </li>
    """
  end

  defp row_kind(:question), do: "q"
  defp row_kind(:problem), do: "p"
  defp row_kind(:neutral), do: nil

  attr :name, :string, required: true
  attr :href, :string, required: true
  attr :kind, :atom, required: true, values: [:working, :waiting, :stopped, :done, :idle]
  attr :word, :string, required: true
  attr :for_you, :integer, default: 0
  attr :detail, :string, default: nil, doc: "phone only: what a Working agent is doing"
  attr :pin, :boolean, default: false, doc: "stays when the team list is closed"

  @doc "One teammate in a team list: glyph, name, status word and the \"N for you\" chip."
  def team_row(assigns) do
    {_symbol, colour} = Map.fetch!(@status, assigns.kind)
    assigns = assign(assigns, :word_class, assigns.kind in [:working, :stopped] && colour)

    ~H"""
    <li class={@pin && "pin"}>
      <.link class="mate" navigate={@href}>
        <.status_glyph kind={@kind} /><span class="m-name">{@name}</span><span class={[
          "m-word",
          @word_class
        ]}>{@word}<span :if={@detail}><span aria-hidden="true"> · </span>{@detail}</span></span><span
          :if={@for_you > 0}
          class="fy"
        >{@for_you}<span class="fy-t"> for you</span></span><span :if={@for_you <= 0}></span>
      </.link>
    </li>
    """
  end

  ## ── Inputs and quiet states ───────────────────────────────────

  attr :label, :string, required: true, doc: "visually hidden label"
  attr :placeholder, :string, default: "Search"
  attr :name, :string, default: "q"
  attr :value, :string, default: nil
  attr :kbd, :string, default: nil
  attr :rest, :global

  @doc "Search capsule: icon, hidden label, input, optional kbd chip."
  def search_capsule(assigns) do
    ~H"""
    <label class="search">
      <.r3_icon name="i-search" /><span class="sr">{@label}</span>
      <input
        type="search"
        name={@name}
        value={@value}
        placeholder={@placeholder}
        autocomplete="off"
        {@rest}
      />
      <kbd :if={@kbd}>{@kbd}</kbd>
    </label>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :help, :string, required: true, doc: "what sending does"
  attr :button, :string, required: true
  attr :name, :string, default: "body"
  attr :rest, :global

  @doc "Labelled reply field with its effect line and a secondary send."
  def composer(assigns) do
    ~H"""
    <form class="composer" {@rest}>
      <label for={@id}>{@label}</label>
      <textarea id={@id} name={@name} rows="2"></textarea>
      <div class="comp-f">
        <p class="help">{@help}</p>
        <button class="pl" type="submit">{@button}</button>
      </div>
    </form>
    """
  end

  attr :title, :string, required: true
  attr :heading, :string, default: nil
  slot :inner_block, doc: "one line of context"
  slot :action

  @doc "Quiet section: small heading, one plain line, one line of context, one action. No illustration."
  def quiet_empty(assigns) do
    ~H"""
    <div class="gl-sec">
      <h2 :if={@heading} class="gl-h">{@heading}</h2>
      <p class="gl-big">{@title}</p>
      <p :if={@inner_block != []} class="gl-sub">{render_slot(@inner_block)}</p>
      {render_slot(@action)}
    </div>
    """
  end

  ## ── Helpers ───────────────────────────────────────────────────

  defp to_number(%Decimal{} = d), do: Decimal.to_float(d)
  defp to_number(n) when is_number(n), do: n
  defp to_number(_), do: 0

  # 62 → "62", 6.6666 → "6.67", 37.2 → "37.2"
  defp fmt(n) when is_integer(n), do: Integer.to_string(n)

  defp fmt(n) when is_float(n) do
    rounded = Float.round(n, 2)

    if rounded == trunc(rounded),
      do: Integer.to_string(trunc(rounded)),
      else: :erlang.float_to_binary(rounded, [:compact, decimals: 2])
  end
end
