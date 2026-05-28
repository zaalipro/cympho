defmodule CymphoWeb.IssueLive.Show.ReviewGates do
  @moduledoc """
  Stateless function component for the review-gate region:
    * Next-owner banner
    * Cleared-nudges banner (when no gates are active)
    * Active review-gate panel (blockers list + auto-nudge buttons +
      embedded work-product form)

  Computes `gate_resolution` and `next_owner` internally via
  `Helpers.review_gate_resolution/1` and
  `Helpers.next_owner_assignment/2`. Events
  (`resolve_review_gate`, `queue_review_nudge`,
  `validate_work_product`, `attach_work_product`,
  `cancel_work_product`) bubble to the parent LiveView.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  attr :issue, :map, required: true
  attr :runs, :list, default: []
  attr :work_products, :list, default: []
  attr :child_issues, :list, default: []
  attr :all_agents, :list, default: []
  attr :orchestrator_enabled?, :boolean, default: false
  attr :show_work_product_form, :boolean, default: false
  attr :work_product_form, :any, default: nil

  def review_gates(assigns) do
    gate_resolution =
      review_gate_resolution(%{
        issue: assigns.issue,
        runs: assigns.runs,
        work_products: assigns.work_products,
        child_issues: assigns.child_issues,
        all_agents: assigns.all_agents
      })

    next_owner =
      next_owner_assignment(
        %{
          issue: assigns.issue,
          all_agents: assigns.all_agents,
          child_issues: assigns.child_issues,
          orchestrator_enabled?: assigns.orchestrator_enabled?
        },
        gate_resolution
      )

    assigns =
      assigns
      |> assign(:gate_resolution, gate_resolution)
      |> assign(:next_owner, next_owner)

    ~H"""
    <section class="px-4 lg:px-6 pb-5">
      <div
        id="issue-next-owner"
        class="rounded-lg border border-hairline bg-surface-1/45 px-4 py-3"
      >
        <div class="flex flex-col gap-3 lg:flex-row lg:items-center lg:justify-between">
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-[11px] font-590 uppercase tracking-wider text-ink-tertiary">
                Next owner
              </span>
              <span class={next_owner_status_class(@next_owner.status)}>
                {@next_owner.status_label}
              </span>
              <span
                :if={@next_owner.blocker_label}
                class="rounded-full border border-border bg-canvas px-2 py-0.5 text-[11px] text-ink-tertiary"
              >
                {@next_owner.blocker_label}
              </span>
            </div>
            <div class="mt-2 flex flex-wrap items-baseline gap-x-2 gap-y-1">
              <h2 class="text-base font-590 text-ink">{@next_owner.owner}</h2>
              <span class="text-xs text-ink-tertiary">{@next_owner.role}</span>
            </div>
            <p class="mt-1 max-w-4xl text-sm leading-5 text-ink-muted">
              {@next_owner.reason}
            </p>
          </div>

          <div class="flex shrink-0 flex-wrap gap-2">
            <%= for action <- @next_owner.actions do %>
              <a
                :if={action.type == :anchor}
                href={action.href}
                class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
              >
                {action.label}
              </a>
              <button
                :if={action.type == :event}
                type="button"
                phx-click="resolve_review_gate"
                phx-value-action={action.action}
                class="rounded-md border border-border bg-panel px-2.5 py-1.5 text-xs font-510 text-ink-muted transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
              >
                {action.label}
              </button>
            <% end %>
          </div>
        </div>
      </div>
    </section>

    <section
      :if={!@gate_resolution[:active?] and !Enum.empty?(@gate_resolution.cleared_nudges)}
      class="px-4 lg:px-6 pb-5"
    >
      <div class="rounded-lg border border-emerald-500/25 bg-emerald-500/[0.06] px-4 py-3">
        <div class="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-sm font-590 text-ink">Review nudges satisfied</h2>
              <span class="rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2 py-0.5 text-[10px] font-510 text-emerald-200">
                Cleared
              </span>
            </div>
            <p class="mt-1 max-w-3xl text-sm leading-5 text-ink-muted">
              The latest requested evidence has landed, so the matching inbox marker was cleared.
            </p>
          </div>

          <div class="flex flex-wrap gap-2 md:justify-end">
            <span
              :for={nudge <- Enum.take(@gate_resolution.cleared_nudges, 3)}
              class="rounded-md border border-emerald-500/20 bg-canvas px-2.5 py-1.5 text-xs text-emerald-100"
            >
              {Enum.join(nudge.blocker_labels, ", ")}
            </span>
          </div>
        </div>
      </div>
    </section>

    <section :if={@gate_resolution[:active?]} class="px-4 lg:px-6 pb-5">
      <div class="rounded-lg border border-amber-500/25 bg-amber-500/[0.07]">
        <div class="flex flex-col gap-3 border-b border-amber-500/20 px-4 py-3 lg:flex-row lg:items-start lg:justify-between">
          <div>
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="text-sm font-590 text-ink">Resolve review gates</h2>
              <span class="rounded-full border border-amber-500/30 bg-amber-500/10 px-2 py-0.5 text-[10px] font-510 text-amber-200">
                {length(@gate_resolution.blockers)} blocking
              </span>
            </div>
            <p class="mt-1 max-w-3xl text-sm leading-5 text-ink-muted">
              The issue cannot move to review or close until these evidence gaps are handled.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <%= for action <- @gate_resolution.actions do %>
              <a
                :if={action.type == :anchor}
                href={action.href}
                class="rounded-md border border-amber-500/30 bg-panel px-2.5 py-1.5 text-xs font-510 text-amber-100 transition-colors hover:bg-amber-500/15 hover:text-amber-50"
              >
                {action.label}
              </a>
              <button
                :if={action.type == :event}
                type="button"
                phx-click="resolve_review_gate"
                phx-value-action={action.action}
                class="rounded-md border border-amber-500/30 bg-panel px-2.5 py-1.5 text-xs font-510 text-amber-100 transition-colors hover:bg-amber-500/15 hover:text-amber-50"
              >
                {action.label}
              </button>
            <% end %>
          </div>
        </div>

        <div class="grid gap-px bg-amber-500/15 md:grid-cols-2 xl:grid-cols-3">
          <div
            :for={blocker <- @gate_resolution.blockers}
            class="bg-canvas/70 px-4 py-3"
          >
            <p class="text-xs font-590 text-amber-100">{blocker.label}</p>
            <p class="mt-1 text-xs leading-5 text-ink-tertiary">{blocker.prompt}</p>
          </div>
        </div>

        <div class="border-t border-amber-500/20 bg-canvas/45 px-4 py-4">
          <div class="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h3 class="text-sm font-590 text-ink">Auto-nudges</h3>
              <p class="mt-1 text-xs leading-5 text-ink-tertiary">
                Queue the right agent into inbox and wake them with the exact missing evidence.
              </p>
            </div>
            <span class="text-xs text-ink-tertiary">
              {length(@gate_resolution.nudges)} suggested
            </span>
          </div>

          <div class="grid gap-3 xl:grid-cols-2">
            <div
              :for={nudge <- @gate_resolution.nudges}
              class="rounded-lg border border-hairline bg-surface-1/70 px-3 py-3"
            >
              <div class="flex items-start justify-between gap-3">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <p class="truncate text-sm font-510 text-ink">{nudge.agent_name}</p>
                    <span class="rounded bg-canvas px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                      {nudge.agent_role || "unrouted"}
                    </span>
                    <span class={[
                      "rounded-full border px-2 py-0.5 text-[10px] font-510",
                      if(nudge.queued?,
                        do: "border-brand/30 bg-brand/10 text-brand",
                        else: "border-amber-500/30 bg-amber-500/10 text-amber-100"
                      )
                    ]}>
                      {nudge.status_label}
                    </span>
                  </div>
                  <p class="mt-1 text-caption text-ink-tertiary">{nudge.summary}</p>
                  <p class="mt-2 text-[11px] leading-4 text-ink-tertiary">
                    Covers {length(nudge.blocker_labels)} gate{if length(nudge.blocker_labels) ==
                                                                    1, do: "", else: "s"}: {Enum.join(
                      nudge.blocker_labels,
                      ", "
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="queue_review_nudge"
                  phx-value-key={nudge.key}
                  disabled={!nudge.enabled?}
                  class={[
                    "shrink-0 rounded-md border px-2.5 py-1.5 text-xs font-510 transition-colors",
                    if(nudge.enabled?,
                      do:
                        "border-brand/30 bg-brand/10 text-brand hover:border-brand/50 hover:bg-brand/15",
                      else: "cursor-not-allowed border-border bg-canvas text-ink-tertiary"
                    )
                  ]}
                >
                  {nudge.button_label}
                </button>
              </div>
              <p class="mt-3 rounded-md bg-canvas px-3 py-2 text-xs leading-5 text-ink-muted">
                {nudge.prompt}
              </p>
            </div>

            <p
              :if={Enum.empty?(@gate_resolution.nudges)}
              class="rounded-lg border border-dashed border-hairline px-3 py-4 text-sm text-ink-tertiary"
            >
              No automatic nudge is available for the current gate state.
            </p>
          </div>
        </div>

        <div
          :if={@show_work_product_form}
          id="issue-work-product-form"
          class="border-t border-amber-500/20 bg-canvas/55 px-4 py-4"
        >
          <div class="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h3 class="text-sm font-590 text-ink">Attach artifact evidence</h3>
              <p class="mt-1 text-xs leading-5 text-ink-tertiary">
                Add a deliverable, spec, URL, or other proof so reviewers can see what changed.
              </p>
            </div>
          </div>

          <.simple_form
            for={@work_product_form}
            id="work-product-form"
            phx-change="validate_work_product"
            phx-submit="attach_work_product"
            class="grid gap-3 lg:grid-cols-[1fr_220px]"
          >
            <.input
              field={@work_product_form[:title]}
              label="Title"
              placeholder="Short evidence title"
              required
            />
            <.input
              field={@work_product_form[:kind]}
              type="select"
              label="Kind"
              options={work_product_kind_options()}
              required
            />
            <div class="lg:col-span-2">
              <.input
                field={@work_product_form[:url]}
                label="URL"
                placeholder="https://github.com/org/repo/pull/123"
              />
            </div>
            <div class="lg:col-span-2">
              <.input
                field={@work_product_form[:description]}
                type="textarea"
                rows={4}
                label="Description"
                placeholder="What this artifact proves, who produced it, and what a reviewer should inspect."
              />
            </div>
            <:actions>
              <.button type="submit" size="sm">Attach work product</.button>
              <.button type="button" variant="ghost" size="sm" phx-click="cancel_work_product">
                Cancel
              </.button>
            </:actions>
          </.simple_form>
        </div>
      </div>
    </section>
    """
  end
end
