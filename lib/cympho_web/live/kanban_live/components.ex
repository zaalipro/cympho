defmodule CymphoWeb.KanbanLive.Components do
  @moduledoc """
  The Board's card (build-spec §5, state a): ID and priority, a two-line
  title, the person and one state chip. Cards that need the owner are lifted;
  the others are quiet. The card keeps the SortableJS contract (`data-kanban-card`,
  `data-issue-id`, `data-status`, `data-allowed-statuses`) and a status menu,
  which is how a card moves without dragging (phones, keyboards).
  """
  use Phoenix.Component
  import CymphoWeb.Components, only: [pending_wake_badge: 1]
  import CymphoWeb.Components.IssueDigest
  import CymphoWeb.Components.R3
  alias CymphoWeb.IssueLive.Tasks
  alias CymphoWeb.KanbanLive.Index

  attr :issue, :map, required: true
  attr :ctx, :map, required: true, doc: "CymphoWeb.IssueLive.Tasks.context/3"
  attr :digest, :map, default: nil
  attr :digest_density, :string, default: "compact"
  attr :agent_heartbeat_states, :map, default: %{}
  attr :pending_wake, :any, default: nil
  attr :launch_readiness, :map, default: nil
  attr :digest_cause_hoisted, :boolean, default: false

  def board_card(assigns) do
    issue = assigns.issue

    assigns =
      assign(assigns,
        chip: Tasks.chip(issue, assigns.ctx),
        lifted?: Tasks.needs_you?(issue, assigns.ctx),
        next_statuses: Index.valid_next_statuses(issue.status),
        identifier: issue.identifier || "CYM-" <> String.slice(issue.id, 0, 4)
      )

    ~H"""
    <li
      class={["bc kanban-card-enter", !@lifted? && "quiet"]}
      data-issue-id={@issue.id}
      data-kanban-card
      data-status={@issue.status}
      data-allowed-statuses={Enum.map_join(@next_statuses, ",", &to_string/1)}
    >
      <div class="bc-top">
        <span class="mono">{@identifier}</span>
        <span class="bc-top-r">
          <Tasks.priority priority={@issue.priority} label={false} />
          <details
            :if={@next_statuses != []}
            class="bc-mv"
            data-no-drag
            phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
          >
            <summary aria-label="Move issue" title="Move issue">
              <span class="hero-ellipsis-horizontal-mini" aria-hidden="true"></span>
            </summary>
            <div class="bc-menu">
              <button
                :for={next_status <- @next_statuses}
                type="button"
                phx-click="transition_issue"
                phx-value-id={@issue.id}
                phx-value-to_status={next_status}
                data-kanban-action
              >
                {Index.status_label(next_status)}
              </button>
            </div>
          </details>
        </span>
      </div>
      <.link class="bc-t" navigate={"/issues/#{@issue.id}?from=/kanban"} draggable="false">
        {@issue.title}
      </.link>
      <p :if={@issue.assignee || @chip} class="bc-f">
        <span
          :if={@issue.assignee}
          class="bc-who"
          title={"#{@issue.assignee.name} · #{role_label(@issue.assignee)} · #{heartbeat(@agent_heartbeat_states, @issue.assignee)}"}
        >
          <span class="tile-ag sm" aria-hidden="true">{Tasks.initials(@issue.assignee.name)}</span>{@issue.assignee.name}
        </span>
        <span :if={@chip} class={["bchip", elem(@chip, 0)]}>
          <.status_glyph :if={elem(@chip, 1)} kind={elem(@chip, 1)} />{elem(@chip, 2)}
        </span>
      </p>
      <div class="bc-x ui-advanced-only">
        <.pending_wake_badge :if={@pending_wake} wake={@pending_wake} />
        <a
          :if={@issue.github_pr_url}
          href={@issue.github_pr_url}
          target="_blank"
          rel="noopener noreferrer"
          data-no-drag
          class="lnk"
        >
          PR
        </a>
        <.issue_digest_card
          issue={@issue}
          digest={@digest}
          density={@digest_density}
          variant={if @digest_density == "compact", do: "inline", else: "card"}
          cause_hoisted={@digest_cause_hoisted}
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
      </div>
    </li>
    """
  end

  @doc "What an empty column says."
  def empty_column_message(:backlog), do: "No unplanned work"
  def empty_column_message(:todo), do: "Nothing queued up"
  def empty_column_message(:in_progress), do: "Nothing running"
  def empty_column_message(:in_review), do: "Nothing to review"
  def empty_column_message(:done), do: "No completed work yet"
  def empty_column_message(:blocked), do: "No blockers"
  def empty_column_message(:cancelled), do: "No cancelled work"

  defp role_label(%{role: role}) when not is_nil(role),
    do: role |> to_string() |> String.replace("_", " ")

  defp role_label(_agent), do: "agent"

  defp heartbeat(states, agent),
    do: Index.get_heartbeat_state(states, agent.id).status || :offline

  defp launch_readiness_chip_class(%{class: class}) do
    "mt-2 inline-flex max-w-full items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10px] font-510 transition-colors hover:border-brand/40 hover:bg-brand/10 " <>
      to_string(class)
  end

  defp launch_readiness_icon(:ready), do: "hero-check-mini"
  defp launch_readiness_icon(:review_mode), do: "hero-eye-mini"
  defp launch_readiness_icon(:attention), do: "hero-wrench-screwdriver-mini"
  defp launch_readiness_icon(:blocked), do: "hero-exclamation-triangle-mini"
  defp launch_readiness_icon(_status), do: "hero-information-circle-mini"
end
