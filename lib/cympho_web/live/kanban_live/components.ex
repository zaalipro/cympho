defmodule CymphoWeb.KanbanLive.Components do
  use Phoenix.Component
  import CymphoWeb.Components, only: [pending_wake_badge: 1]
  import CymphoWeb.Components.IssueDigest
  alias CymphoWeb.KanbanLive.Index

  # A card counts as quietly stuck after this many hours without movement.
  @stale_after_hours 48
  @stale_statuses [:todo, :in_progress, :in_review]

  # Columns where a high card count is a real overload signal (not an archive).
  @overload_statuses [:todo, :in_progress, :in_review, :blocked]
  @soft_overload_threshold 8

  attr :issue, :map, required: true
  attr :status, :atom, required: true
  attr :digest_density, :string, default: "detailed"
  attr :agents, :list, default: []
  attr :agent_heartbeat_states, :map, default: %{}
  attr :pending_wake, :any, default: nil
  attr :editing_card_id, :any, default: nil
  attr :card_action_open, :any, default: nil
  attr :launch_readiness, :map, default: nil

  def issue_card(assigns) do
    ~H"""
    <div
      class="kanban-card-enter group min-h-[72px] cursor-grab rounded-xl border border-hairline bg-surface-2 p-3 shadow-card transition-all hover:border-border-hover hover:bg-surface-hover hover:shadow-raised active:cursor-grabbing"
      data-issue-id={@issue.id}
      data-kanban-card
    >
      <.pending_wake_badge :if={@pending_wake} wake={@pending_wake} class="mb-2" />

      <div class="flex items-start gap-1.5">
        <span
          data-kanban-drag-handle
          title="Drag issue"
          class="mt-0.5 flex h-5 w-4 shrink-0 cursor-grab items-center justify-center rounded text-text-quaternary transition-colors group-hover:text-text-tertiary active:cursor-grabbing"
        >
          <span class="hero-ellipsis-vertical-mini h-4 w-4"></span>
        </span>
        <.link
          navigate={"/issues/#{@issue.id}"}
          draggable="false"
          class="line-clamp-2 min-w-0 flex-1 text-sm font-590 leading-5 text-text-primary transition-colors hover:text-white"
        >
          {@issue.title}
        </.link>
      </div>

      <.card_meta issue={@issue} agent_heartbeat_states={@agent_heartbeat_states} class="mt-2" />

      <.issue_digest_card
        issue={@issue}
        density={@digest_density}
        variant={if @digest_density == "compact", do: "inline", else: "card"}
        class={["mt-2", @digest_density == "compact" && "ui-advanced-only"]}
      />

      <.link
        :if={@launch_readiness && @digest_density == "compact"}
        navigate={@launch_readiness.path}
        data-no-drag
        title={"#{@launch_readiness.label}: #{@launch_readiness.summary}"}
        aria-label={"#{@launch_readiness.label}: #{@launch_readiness.target}"}
        class={[
          "mt-2 inline-flex h-7 w-7 items-center justify-center rounded-lg border transition-colors hover:border-brand/40 hover:bg-brand/10",
          @launch_readiness.class
        ]}
      >
        <span class={[launch_readiness_icon(@launch_readiness.status), "h-3.5 w-3.5"]}></span>
      </.link>
      <.link
        :if={@launch_readiness && @digest_density != "compact"}
        navigate={@launch_readiness.path}
        data-no-drag
        title={@launch_readiness.summary}
        class={launch_readiness_chip_class(@launch_readiness)}
      >
        <span class="shrink-0">{@launch_readiness.label}</span>
        <span class="min-w-0 truncate opacity-80">{@launch_readiness.target}</span>
      </.link>
      <% next_statuses = Index.valid_next_statuses(@issue.status) %>
      <%= if next_statuses != [] do %>
        <details class="cympho-menu relative ml-auto mt-2 w-fit" data-no-drag>
          <summary
            class="flex h-7 w-7 cursor-pointer list-none items-center justify-center rounded-md text-text-quaternary transition-colors hover:bg-surface-hover hover:text-text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40"
            aria-label="Move issue"
            title="Move issue"
          >
            <span class="hero-ellipsis-horizontal-mini h-4 w-4"></span>
          </summary>
          <div class="cympho-menu-panel absolute right-0 z-30 mt-1 min-w-32 rounded-lg border border-border bg-panel p-1 shadow-dialog">
            <button
              :for={next_status <- next_statuses}
              type="button"
              phx-click="transition_issue"
              phx-value-id={@issue.id}
              phx-value-to_status={next_status}
              data-kanban-action
              class="flex w-full items-center gap-2 rounded-md px-2.5 py-2 text-left text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
              title={"Move to #{Index.status_label(next_status)}"}
            >
              <span class={[
                "h-2 w-2 rounded-full",
                column_dot_class(next_status)
              ]}>
              </span>
              {Index.status_label(next_status)}
            </button>
          </div>
        </details>
      <% end %>
    </div>
    """
  end

  @doc """
  One quiet metadata line for a board card: identifier chip, elevated-priority
  chip (high/critical only), blocker count, stale tick, hover-revealed extras
  (comments, PR), and the assignee avatar pinned right.
  """
  attr :issue, :map, required: true
  attr :agent_heartbeat_states, :map, default: %{}
  attr :show_assignee, :boolean, default: true
  attr :class, :string, default: nil

  def card_meta(assigns) do
    assigns =
      assigns
      |> assign(:blocker_count, length(assigns.issue.blocked_by || []))
      |> assign(:stale_hours, stale_hours(assigns.issue))
      |> assign(:comment_count, length(assigns.issue.comments || []))

    ~H"""
    <div class={["flex min-w-0 items-center gap-2 text-[11px] text-text-quaternary", @class]}>
      <span class="shrink-0 font-mono text-[10px] tracking-[0.02em]">
        {@issue.identifier || "CYM-" <> String.slice(@issue.id, 0, 4)}
      </span>

      <span
        :if={elevated_priority?(@issue.priority)}
        class={"h-3.5 w-3.5 shrink-0 " <> priority_icon_class(@issue.priority)}
        title={"#{String.capitalize(to_string(@issue.priority))} priority"}
        aria-label={"#{String.capitalize(to_string(@issue.priority))} priority"}
      >
      </span>

      <span :if={@blocker_count > 0} class="shrink-0 font-510 text-brand">
        {@blocker_count} {pluralize(@blocker_count, "blocker")}
      </span>

      <span
        :if={@stale_hours}
        class="flex shrink-0 items-center gap-1 text-amber-300/90"
        title={"No movement for #{stale_age_title(@stale_hours)}"}
      >
        <span class="h-1 w-1 rounded-full bg-amber-400"></span>
        {stale_age_label(@stale_hours)}
      </span>

      <span class="ml-auto flex shrink-0 items-center gap-2">
        <span class="flex items-center gap-2 opacity-100 transition-opacity sm:opacity-0 sm:group-hover:opacity-100 sm:group-focus-within:opacity-100">
          <span :if={@comment_count > 0} class="flex items-center gap-1">
            <svg class="h-3 w-3" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M7 8h10M7 12h4m1 8l-4-4H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-3l-4 4z"
              />
            </svg>
            {@comment_count}
            <span class="sr-only">{pluralize(@comment_count, "comment")}</span>
          </span>
          <a
            :if={@issue.github_pr_url}
            href={@issue.github_pr_url}
            target="_blank"
            data-no-drag
            class="text-accent transition-colors hover:text-accent-hover"
            title="GitHub PR"
          >
            PR
          </a>
        </span>
        <.assignee_avatar
          :if={@show_assignee && @issue.assignee}
          agent={@issue.assignee}
          heartbeat_status={
            Index.get_heartbeat_state(@agent_heartbeat_states, @issue.assignee.id).status
          }
        />
      </span>
    </div>
    """
  end

  @doc """
  Compact initials avatar with a role tint and a heartbeat presence dot, so
  who-is-on-a-card reads in one glance on an agent-dense board.
  """
  attr :agent, :map, required: true
  attr :heartbeat_status, :atom, default: nil

  def assignee_avatar(assigns) do
    ~H"""
    <span
      class="relative inline-flex shrink-0"
      title={"#{@agent.name} · #{role_label(@agent)} · #{@heartbeat_status || :offline}"}
    >
      <span class={[
        "flex h-5 w-5 items-center justify-center rounded-full border text-[9px] font-590 uppercase leading-none",
        role_tint_class(@agent)
      ]}>
        {agent_initials(@agent.name)}
      </span>
      <span class={[
        "absolute -bottom-0.5 -right-0.5 h-1.5 w-1.5 rounded-full ring-2 ring-surface-2",
        heartbeat_dot_color(@heartbeat_status)
      ]}>
      </span>
    </span>
    """
  end

  def agent_initials(name) when is_binary(name) do
    name
    |> String.split(~r/\s+/, trim: true)
    |> Enum.take(2)
    |> Enum.map(&String.first/1)
    |> Enum.join()
    |> String.upcase()
  end

  def agent_initials(_name), do: "?"

  defp role_label(%{role: role}) when not is_nil(role),
    do: role |> to_string() |> String.replace("_", " ")

  defp role_label(_agent), do: "agent"

  defp role_tint_class(%{role: role}) when role in [:ceo, :cto],
    do: "border-brand/30 bg-brand/15 text-brand"

  defp role_tint_class(%{role: role}) when role in [:engineer, :release_engineer, :qa_engineer],
    do: "border-sky-500/30 bg-sky-500/15 text-sky-300"

  defp role_tint_class(%{role: role}) when role in [:product_manager, :designer],
    do: "border-violet-500/30 bg-violet-500/15 text-violet-300"

  defp role_tint_class(%{role: role}) when not is_nil(role),
    do: "border-emerald-500/30 bg-emerald-500/15 text-emerald-300"

  defp role_tint_class(_agent), do: "border-border bg-subtle text-text-tertiary"

  defp elevated_priority?(priority), do: priority in [:high, :critical]

  defp stale_hours(%{status: status, updated_at: %DateTime{} = updated_at})
       when status in @stale_statuses do
    hours = DateTime.diff(DateTime.utc_now(), updated_at, :hour)
    if hours >= @stale_after_hours, do: hours
  end

  defp stale_hours(_issue), do: nil

  defp stale_age_label(hours), do: "#{div(hours, 24)}d"

  defp stale_age_title(hours) do
    days = div(hours, 24)
    "#{days} #{pluralize(days, "day")}"
  end

  @doc """
  Class for the column-header count pill: brand when a WIP limit is exceeded,
  a calm amber tint when an active column is clearly backed up, quiet otherwise.
  """
  def column_count_class(_status, _count, true = _exceeded), do: "bg-brand/20 text-brand"

  def column_count_class(status, count, _exceeded)
      when status in @overload_statuses and count > @soft_overload_threshold,
      do: "bg-amber-500/15 text-amber-300"

  def column_count_class(_status, _count, _exceeded), do: "bg-surface text-text-quaternary"

  attr :status, :atom, required: true

  def empty_column_state(assigns) do
    ~H"""
    <div class="flex min-h-[108px] flex-col items-center justify-center rounded-xl border border-dashed border-hairline bg-canvas/40 px-4 py-6 text-center">
      <div class="mb-2 flex h-8 w-8 items-center justify-center rounded-xl bg-subtle">
        {empty_column_icon(@status)}
      </div>
      <p class="text-xs text-text-quaternary">{empty_column_message(@status)}</p>
    </div>
    """
  end

  defp empty_column_icon(:backlog) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10"/></svg>|
    )
  end

  defp empty_column_icon(:todo) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"/></svg>|
    )
  end

  defp empty_column_icon(:in_progress) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 10V3L4 14h7v7l9-11h-7z"/></svg>|
    )
  end

  defp empty_column_icon(:in_review) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/></svg>|
    )
  end

  defp empty_column_icon(:done) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>|
    )
  end

  defp empty_column_icon(:blocked) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M18.364 18.364A9 9 0 005.636 5.636m12.728 12.728A9 9 0 015.636 5.636m12.728 12.728L5.636 5.636"/></svg>|
    )
  end

  defp empty_column_icon(:cancelled) do
    Phoenix.HTML.raw(
      ~s|<svg class="w-4 h-4 text-text-quaternary" fill="none" stroke="currentColor" viewBox="0 0 24 24"><path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M10 14l2-2m0 0l2-2m-2 2l-2-2m2 2l2 2m7-2a9 9 0 11-18 0 9 9 0 0118 0z"/></svg>|
    )
  end

  defp empty_column_message(:backlog), do: "No unplanned work"
  defp empty_column_message(:todo), do: "Nothing queued up"
  defp empty_column_message(:in_progress), do: "Nothing in flight"
  defp empty_column_message(:in_review), do: "Nothing to review"
  defp empty_column_message(:done), do: "No completed work yet"
  defp empty_column_message(:blocked), do: "No blockers"
  defp empty_column_message(:cancelled), do: "No cancelled work"

  @doc "Filled status dot for a column header, keyed to status."
  def column_dot_class(:backlog), do: "bg-text-quaternary"
  def column_dot_class(:todo), do: "bg-sky-500"
  def column_dot_class(:in_progress), do: "bg-brand"
  def column_dot_class(:in_review), do: "bg-amber-500"
  def column_dot_class(:blocked), do: "bg-brand"
  def column_dot_class(:done), do: "bg-emerald-500"
  def column_dot_class(:cancelled), do: "bg-text-tertiary"
  def column_dot_class(_), do: "bg-border"

  @doc "2px left-accent color for a column header, keyed to status."
  def column_accent_class(:backlog), do: "border-l-text-quaternary"
  def column_accent_class(:todo), do: "border-l-sky-500"
  def column_accent_class(:in_progress), do: "border-l-brand"
  def column_accent_class(:in_review), do: "border-l-amber-500"
  def column_accent_class(:blocked), do: "border-l-brand"
  def column_accent_class(:done), do: "border-l-emerald-500"
  def column_accent_class(:cancelled), do: "border-l-text-tertiary"
  def column_accent_class(_), do: "border-l-border"

  @doc "Status-tinted gradient wash for a column header, keyed to status."
  def column_wash_class(:backlog), do: "bg-gradient-to-b from-slate-500/10 to-transparent"
  def column_wash_class(:todo), do: "bg-gradient-to-b from-sky-500/10 to-transparent"
  def column_wash_class(:in_progress), do: "bg-gradient-to-b from-brand/10 to-transparent"
  def column_wash_class(:in_review), do: "bg-gradient-to-b from-amber-500/10 to-transparent"
  def column_wash_class(:blocked), do: "bg-gradient-to-b from-brand/10 to-transparent"
  def column_wash_class(:done), do: "bg-gradient-to-b from-emerald-500/10 to-transparent"
  def column_wash_class(:cancelled), do: "bg-gradient-to-b from-slate-500/10 to-transparent"
  def column_wash_class(_), do: ""

  def priority_class(:critical), do: "bg-brand/20 text-brand"
  def priority_class(:high), do: "bg-amber-400/20 text-amber-300"
  def priority_class(:medium), do: "bg-yellow-500/20 text-yellow-400"
  def priority_class(:low), do: "bg-emerald-500/20 text-emerald-400"
  def priority_class(_), do: "bg-surface text-text-quaternary"

  # Board cards show elevated priority as a single mini icon, not a word chip.
  def priority_icon_class(:critical), do: "hero-exclamation-triangle-mini text-brand"
  def priority_icon_class(_), do: "hero-chevron-double-up-mini text-amber-300"

  defp launch_readiness_chip_class(%{class: class}) do
    "mt-2 inline-flex max-w-full items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10px] font-510 transition-colors hover:border-brand/40 hover:bg-brand/10 " <>
      to_string(class)
  end

  defp launch_readiness_icon(:ready), do: "hero-check-mini"
  defp launch_readiness_icon(:review_mode), do: "hero-eye-mini"
  defp launch_readiness_icon(:attention), do: "hero-wrench-screwdriver-mini"
  defp launch_readiness_icon(:blocked), do: "hero-exclamation-triangle-mini"
  defp launch_readiness_icon(_status), do: "hero-information-circle-mini"

  defp heartbeat_dot_color(:idle), do: "bg-emerald-400"
  defp heartbeat_dot_color(:running), do: "bg-yellow-400 animate-pulse"
  defp heartbeat_dot_color(:working), do: "bg-yellow-400 animate-pulse"
  defp heartbeat_dot_color(:error), do: "bg-brand"
  defp heartbeat_dot_color(:paused), do: "bg-text-tertiary"
  defp heartbeat_dot_color(:offline), do: "bg-text-quaternary"
  defp heartbeat_dot_color(_), do: "bg-text-quaternary"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"
end
