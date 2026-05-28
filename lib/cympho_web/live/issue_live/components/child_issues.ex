defmodule CymphoWeb.IssueLive.Show.ChildIssues do
  @moduledoc """
  Stateless function component for the issue decomposition / sub-issues
  tree. Renders a flat list of descendants (depth-indented) with badge,
  evidence chips, and the next-step hint from the child-health card.

  No events — all interaction is navigation (`<.app_link>`).
  """
  use CymphoWeb, :html

  attr :child_tree, :list, required: true
  attr :child_health_cards, :list, default: []

  def child_issues(assigns) do
    assigns =
      assign(
        assigns,
        :health_by_child_id,
        Map.new(assigns.child_health_cards, fn card -> {card.issue_id, card} end)
      )

    ~H"""
    <div :if={!Enum.empty?(@child_tree)} id="issue-sub-issues" class="px-4 lg:px-6 pb-5">
      <div class="border-y border-hairline bg-surface-1/25">
        <div class="flex items-center justify-between gap-3 px-1 py-3">
          <h2 class="text-eyebrow text-ink-tertiary uppercase">Decomposition</h2>
          <span class="text-caption text-ink-tertiary">
            {length(@child_tree)} {if length(@child_tree) == 1, do: "issue", else: "issues"} in subtree
          </span>
        </div>
        <div class="divide-y divide-hairline">
          <.app_link
            :for={node <- @child_tree}
            navigate={~p"/issues/#{node.issue.id}"}
            class="group flex items-start gap-3 py-3 hover:bg-surface-1/60 transition-colors"
            style={"padding-left: #{node.depth * 18 + 4}px;"}
          >
            <% health = Map.get(@health_by_child_id, node.issue.id) %>
            <span
              :if={node.depth > 0}
              aria-hidden="true"
              class="mt-2 inline-block w-2 shrink-0 border-l border-b border-hairline-strong rounded-bl-sm self-stretch"
              style="height: 14px;"
            ></span>
            <div class="min-w-0 flex-1">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-mono text-caption text-ink-tertiary">
                  {node.issue.identifier || "CYM-?"}
                </span>
                <span class="truncate text-sm font-510 text-ink group-hover:text-primary">
                  {node.issue.title}
                </span>
                <span
                  :if={node.depth >= 3 and node.has_children?}
                  class="rounded bg-surface-1 px-1.5 py-0.5 font-mono text-[10px] text-ink-tertiary"
                  title="More descendants below this node — open the issue to drill in."
                >
                  +more
                </span>
              </div>
              <p
                :if={node.issue.description not in [nil, ""]}
                class="mt-1 line-clamp-2 text-caption text-ink-tertiary"
              >
                {node.issue.description}
              </p>
              <div :if={health} class="mt-2 flex flex-wrap gap-1.5">
                <span
                  :for={chip <- health.evidence}
                  class={chip_class(chip.status)}
                >
                  {chip.label}
                </span>
              </div>
              <p :if={health} class="mt-2 text-caption text-ink-tertiary">
                Next: {health.next}
              </p>
            </div>
            <div class="flex shrink-0 flex-col items-end gap-1 pr-1">
              <.badge variant="status" value={to_string(node.issue.status)} />
              <span :if={health} class={state_class(health.state)}>
                {health.review_label}
              </span>
              <span class="text-caption text-ink-tertiary">
                {(node.issue.assignee && node.issue.assignee.name) ||
                  (node.issue.assigned_role && "Role: #{node.issue.assigned_role}") ||
                  "Unassigned"}
              </span>
            </div>
          </.app_link>
        </div>
      </div>
    </div>
    """
  end

  defp state_class(:ready_for_cto),
    do:
      "shrink-0 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-emerald-300"

  defp state_class(:missing_evidence),
    do:
      "shrink-0 rounded-full border border-amber-500/25 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-amber-300"

  defp state_class(:blocked),
    do:
      "shrink-0 rounded-full border border-red-500/25 bg-red-500/10 px-2 py-0.5 text-[10px] font-510 uppercase text-red-300"

  defp state_class(:closed),
    do:
      "shrink-0 rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] font-510 uppercase text-ink-tertiary"

  defp chip_class(:complete),
    do:
      "rounded-full border border-emerald-500/20 bg-emerald-500/10 px-2 py-0.5 text-[10px] uppercase text-emerald-300"

  defp chip_class(:blocked),
    do: "rounded-full border border-red-500/20 bg-red-500/10 px-2 py-0.5 text-[10px] uppercase text-red-300"

  defp chip_class(:missing),
    do: "rounded-full border border-hairline bg-surface-1 px-2 py-0.5 text-[10px] uppercase text-ink-tertiary"
end
