defmodule CymphoWeb.IssueLive.Show.ActivityTimeline do
  @moduledoc """
  Stateless function component for the issue activity timeline:
  filter chips, comments, runs, interactions, work products, and tool
  call traces.

  All events (`set_timeline_filter`, `delete_comment`,
  `resolve_interaction`, `respond_questions`) bubble to the parent
  LiveView, which owns the timeline state and persistence.
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  attr :timeline, :list, required: true
  attr :timeline_filter, :string, required: true
  attr :all_agents, :list, default: []

  def activity_timeline(assigns) do
    assigns = assign(assigns, :visible_timeline, filtered_timeline(assigns.timeline, assigns.timeline_filter))

    ~H"""
    <div id="issue-activity" class="px-4 lg:px-6 pb-3">
      <div class="flex flex-col gap-3 border-t border-border/60 pt-5 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 class="text-eyebrow text-ink-tertiary uppercase">Activity</h2>
          <p class="mt-1 text-caption text-ink-tertiary">
            {timeline_summary(@timeline, @timeline_filter)}
          </p>
          <p
            :if={@timeline_filter == "signal"}
            class="mt-1 max-w-[520px] text-[11px] leading-4 text-ink-tertiary"
          >
            Signal mode keeps tagged comments, artifacts, failed runs, and completed runs with summaries visible while folding routine chatter into All.
          </p>
        </div>
        <div class="flex max-w-full gap-1 overflow-x-auto rounded-lg border border-border bg-surface p-1">
          <button
            :for={{filter, label, count, title} <- timeline_filter_options(@timeline)}
            type="button"
            title={title}
            phx-click="set_timeline_filter"
            phx-value-filter={filter}
            class={[
              "inline-flex shrink-0 items-center gap-1.5 rounded-md px-2.5 py-1.5 text-xs font-510 transition-colors",
              if(@timeline_filter == filter,
                do: "bg-brand text-white",
                else: "text-text-tertiary hover:bg-surface-hover hover:text-text-primary"
              )
            ]}
          >
            <span>{label}</span>
            <span class={[
              "rounded-full px-1.5 py-0.5 text-[10px]",
              if(@timeline_filter == filter,
                do: "bg-white/20 text-white",
                else: "bg-canvas text-text-quaternary"
              )
            ]}>
              {count}
            </span>
          </button>
        </div>
      </div>
    </div>
    <div
      id="timeline-stream"
      class="flex-1 overflow-y-auto px-4 lg:px-6 pb-4 space-y-4"
      phx-hook="TimelineScroll"
    >
      <div
        :if={Enum.empty?(@visible_timeline)}
        class="rounded-lg border border-dashed border-border bg-subtle px-4 py-10 text-center text-sm text-text-tertiary"
      >
        {timeline_empty_message(@timeline_filter)}
      </div>
      <div
        :for={entry <- @visible_timeline}
        id={"entry-#{entry.type}-#{entry.id}"}
        class="flex gap-3"
      >
        <div class="flex-shrink-0 flex flex-col items-center gap-1">
          <div class={
            case entry.type do
              :comment ->
                author_type = Map.get(entry.data, :author_type)

                cond do
                  author_type == "agent" ->
                    "w-8 h-8 rounded-full bg-brand/20 text-brand flex items-center justify-center text-xs font-510"

                  author_type == "system" ->
                    "w-8 h-8 rounded-full bg-subtle border border-dashed border-border/50 flex items-center justify-center text-text-quaternary"

                  true ->
                    "w-8 h-8 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-xs font-510"
                end

              :interaction ->
                "w-8 h-8 rounded-full bg-accent/20 text-accent flex items-center justify-center text-xs font-510"

              :run ->
                "w-8 h-8 rounded-full bg-surface border border-border flex items-center justify-center text-text-quaternary"

              _ ->
                "w-8 h-8 rounded-full bg-surface border border-border flex items-center justify-center text-text-quaternary"
            end
          }>
            {case entry.type do
              :comment ->
                author_type = Map.get(entry.data, :author_type)

                cond do
                  author_type == "agent" ->
                    agent = Enum.find(@all_agents, &(&1.id == entry.data.author_id))
                    String.first((agent && agent.name) || "A")

                  author_type == "system" ->
                    "⚙️"

                  true ->
                    "U"
                end

              :interaction ->
                case entry.data.kind do
                  :suggest_tasks -> "📋"
                  :ask_user_questions -> "?"
                  :request_confirmation -> "✓"
                  _ -> "•"
                end

              :run ->
                status = entry.data.status || "pending"

                case status do
                  "completed" -> "✓"
                  "failed" -> "✕"
                  "running" -> "▶"
                  _ -> "○"
                end

              _ ->
                "•"
            end}
          </div>
          <div class="w-0.5 flex-1 bg-border/30 min-h-[8px]"></div>
        </div>

        <div class="flex-1 min-w-0">
          <div
            :if={entry.type == :comment}
            class={"rounded-lg border border-border bg-surface p-4 #{if entry.data.author_type == "system", do: "border-dashed bg-subtle", else: ""}"}
          >
            <div
              :if={entry.data.author_type != "system"}
              class="mb-2 flex items-center justify-between"
            >
              <div class="flex items-center gap-2">
                <span class="text-xs font-510 text-text-secondary">
                  {case entry.data.author_type do
                    "agent" ->
                      agent = Enum.find(@all_agents, &(&1.id == entry.data.author_id))
                      if agent, do: agent.name, else: "Agent"

                    _ ->
                      entry.data.author_id || "User"
                  end}
                </span>
                <span
                  :if={entry.data.author_type == "agent"}
                  class="rounded bg-brand/10 px-1.5 py-0.5 text-[10px] text-brand"
                >
                  Agent
                </span>
                <span class={"rounded border px-1.5 py-0.5 text-[10px] font-510 #{comment_category_class(entry.data)}"}>
                  {comment_category_label(entry.data)}
                </span>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-xs text-text-quaternary">
                  {format_timeline_timestamp(entry.timestamp)}
                </span>
                <button
                  type="button"
                  class="text-xs text-text-quaternary opacity-0 transition-colors hover:text-red-400 group-hover:opacity-100"
                  phx-click="delete_comment"
                  phx-value-id={entry.data.id}
                  data-confirm="Delete this comment?"
                >
                  <.icon name="hero-x-mark" class="h-3 w-3" />
                </button>
              </div>
            </div>
            <p class={
              if entry.data.author_type == "system",
                do: "text-xs text-text-quaternary",
                else: "whitespace-pre-wrap text-sm text-text-secondary"
            }>
              {entry.data.body}
            </p>
          </div>

          <div
            :if={entry.type == :run}
            class="rounded-lg border border-border/50 bg-subtle p-3"
          >
            <% run_agent = Enum.find(@all_agents, &(&1.id == entry.data.agent_id)) %>
            <% adapter_error = adapter_error_for_run(entry.data) %>
            <div class="mb-2 flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class={"h-2 w-2 rounded-full #{run_status_color(entry.data.status)}"}>
                </span>
                <span class="text-xs font-510 text-text-primary">
                  {run_status_label(entry.data.status)}
                </span>
                <span class="text-xs text-text-quaternary">
                  {entry.data.adapter || "unknown"}
                </span>
                <span class="text-xs text-text-quaternary">
                  by {(run_agent && run_agent.name) || "unknown agent"}
                </span>
              </div>
              <span class="text-xs text-text-quaternary">
                {format_timeline_timestamp(entry.timestamp)}
              </span>
            </div>
            <div class="flex items-center gap-3 text-xs text-text-quaternary">
              <span>{format_run_duration(entry.data)}</span>
              <span :if={entry.data.input_tokens > 0 or entry.data.output_tokens > 0}>
                {format_tokens(entry.data.input_tokens + entry.data.output_tokens)} tokens
              </span>
              <span :if={positive_cost?(entry.data.cost_usd)}>
                {format_cost(entry.data.cost_usd)}
              </span>
              <span :if={entry.data.invocation_source not in [nil, ""]}>
                {String.replace(entry.data.invocation_source, "_", " ")}
              </span>
            </div>
            <p
              :if={entry.data.continuation_summary not in [nil, ""]}
              class="mt-2 whitespace-pre-wrap text-xs text-text-secondary"
            >
              {entry.data.continuation_summary}
            </p>
            <div
              :if={adapter_error}
              class="mt-3 rounded-lg border border-red-500/20 bg-red-500/[0.06] p-3"
            >
              <div class="flex flex-wrap items-center gap-2">
                <span class={"inline-flex rounded-full border px-2 py-0.5 text-[11px] font-510 #{adapter_error_badge_class(adapter_error.category)}"}>
                  {adapter_error_category_label(adapter_error.category)}
                </span>
                <span class="text-xs font-510 text-text-primary">{adapter_error.title}</span>
              </div>
              <p class="mt-2 text-xs leading-5 text-text-secondary">{adapter_error.message}</p>
              <p :if={adapter_error.hint not in [nil, ""]} class="mt-1 text-xs text-text-tertiary">
                {adapter_error.hint}
              </p>
              <details
                :if={adapter_error.detail not in [nil, ""]}
                class="mt-2 text-xs text-text-tertiary"
              >
                <summary class="cursor-pointer select-none text-text-quaternary hover:text-text-secondary">
                  Show adapter details
                </summary>
                <pre class="mt-2 max-h-40 overflow-auto whitespace-pre-wrap rounded border border-border bg-canvas px-3 py-2 font-mono text-[11px] leading-5 text-text-secondary"><%= adapter_error.detail %></pre>
              </details>
            </div>
          </div>

          <div
            :if={entry.type == :interaction}
            class="space-y-3 rounded-lg border border-accent/30 bg-surface p-4"
          >
            <div class="flex items-center justify-between">
              <div class="flex items-center gap-2">
                <span class="text-xs font-510 text-accent">
                  {case entry.data.kind do
                    :suggest_tasks -> "Suggested Tasks"
                    :ask_user_questions -> "Questions"
                    :request_confirmation -> "Confirmation Request"
                  end}
                </span>
                <.badge variant="status" value={to_string(entry.data.status)} />
              </div>
              <span class="text-xs text-text-quaternary">
                {format_timeline_timestamp(entry.timestamp)}
              </span>
            </div>

            <div :if={entry.data.kind == :suggest_tasks} class="space-y-2">
              <p class="text-sm text-text-secondary">
                {Map.get(entry.data.payload, "message", "The agent suggests the following tasks:")}
              </p>
              <div
                :for={{task, idx} <- Enum.with_index(Map.get(entry.data.payload, "tasks", []))}
                class="flex items-start gap-2 rounded-lg bg-subtle p-2"
              >
                <span class="mt-0.5 text-xs text-text-quaternary">{idx + 1}.</span>
                <div class="flex-1">
                  <p class="text-sm font-510 text-text-primary">
                    {Map.get(task, "title", "Untitled")}
                  </p>
                  <p :if={Map.get(task, "description")} class="mt-0.5 text-xs text-text-tertiary">
                    {Map.get(task, "description")}
                  </p>
                </div>
                <div :if={Map.get(task, "accepted")} class="text-xs text-success">Accepted</div>
              </div>
              <div :if={entry.data.status == :pending} class="flex items-center gap-2 pt-2">
                <.button
                  type="button"
                  size="sm"
                  phx-click="resolve_interaction"
                  phx-value-id={entry.data.id}
                  phx-value-status="accepted"
                >
                  Accept Tasks
                </.button>
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="resolve_interaction"
                  phx-value-id={entry.data.id}
                  phx-value-status="rejected"
                >
                  Reject
                </.button>
              </div>
            </div>

            <div :if={entry.data.kind == :ask_user_questions} class="space-y-3">
              <p class="text-sm text-text-secondary">
                {Map.get(entry.data.payload, "message", "The agent has questions:")}
              </p>
              <div
                :for={{q, idx} <- Enum.with_index(Map.get(entry.data.payload, "questions", []))}
                class="space-y-1"
              >
                <p class="text-sm text-text-primary">
                  <span class="text-text-quaternary">{idx + 1}.</span> {Map.get(
                    q,
                    "question",
                    "N/A"
                  )}
                </p>
              </div>
              <div :if={Map.get(entry.data.payload, "response")} class="rounded-lg bg-subtle p-2">
                <p class="text-sm text-text-secondary">
                  {Map.get(entry.data.payload, "response")}
                </p>
              </div>
              <div :if={entry.data.status == :pending} class="pt-2">
                <form phx-submit="respond_questions" class="space-y-2">
                  <input type="hidden" name="_id" value={entry.data.id} />
                  <textarea
                    name="response"
                    placeholder="Type your response..."
                    class="min-h-[60px] w-full resize-y rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary transition-colors placeholder:text-text-quaternary focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/30"
                    required
                  ></textarea>
                  <.button type="submit" size="sm">Respond</.button>
                </form>
              </div>
            </div>

            <div :if={entry.data.kind == :request_confirmation} class="space-y-2">
              <p class="text-sm text-text-secondary">
                {Map.get(entry.data.payload, "message", "Please confirm:")}
              </p>
              <div
                :if={Map.get(entry.data.payload, "details")}
                class="rounded-lg bg-subtle p-2 text-xs text-text-tertiary"
              >
                {Map.get(entry.data.payload, "details")}
              </div>
              <div :if={entry.data.status == :pending} class="flex items-center gap-2 pt-2">
                <.button
                  type="button"
                  size="sm"
                  phx-click="resolve_interaction"
                  phx-value-id={entry.data.id}
                  phx-value-status="accepted"
                >
                  Confirm
                </.button>
                <.button
                  type="button"
                  size="sm"
                  variant="ghost"
                  phx-click="resolve_interaction"
                  phx-value-id={entry.data.id}
                  phx-value-status="rejected"
                >
                  Reject
                </.button>
              </div>
            </div>
          </div>

          <div
            :if={entry.type == :work_product}
            class="rounded-lg border border-brand/25 bg-brand/5 p-4"
          >
            <div class="mb-2 flex items-start justify-between gap-3">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <span class="text-xs font-510 text-brand">Work product</span>
                  <span class="rounded bg-surface-1 px-1.5 py-0.5 text-[10px] uppercase text-ink-tertiary">
                    {format_work_product_kind(entry.data.kind)}
                  </span>
                </div>
                <p class="mt-1 truncate text-sm font-510 text-ink">
                  {entry.data.title}
                </p>
              </div>
              <span class="shrink-0 text-xs text-text-quaternary">
                {format_timeline_timestamp(entry.timestamp)}
              </span>
            </div>
            <p
              :if={entry.data.description not in [nil, ""]}
              class="whitespace-pre-wrap text-sm text-text-secondary"
            >
              {entry.data.description}
            </p>
            <a
              :if={entry.data.url not in [nil, ""]}
              href={entry.data.url}
              target="_blank"
              rel="noopener"
              class="mt-2 inline-flex max-w-full items-center gap-1.5 text-caption text-primary hover:underline"
            >
              <.icon name="hero-arrow-top-right-on-square-mini" class="h-3.5 w-3.5 shrink-0" />
              <span class="truncate">{entry.data.url}</span>
            </a>
            <p
              :if={entry.data.created_by_agent}
              class="mt-2 text-caption text-ink-tertiary"
            >
              Attached by {entry.data.created_by_agent.name}
            </p>
          </div>

          <div
            :if={entry.type == :tool_call_trace}
            class="rounded-lg border border-border/50 bg-subtle p-3"
          >
            <div class="mb-2 flex items-center justify-between gap-3">
              <div class="min-w-0">
                <div class="flex items-center gap-2">
                  <span class={"h-2 w-2 rounded-full #{trace_status_color(entry.data.status)}"}>
                  </span>
                  <span class="truncate text-xs font-510 text-text-primary">
                    {entry.data.tool_name}
                  </span>
                </div>
                <p class="mt-0.5 text-xs text-text-quaternary">
                  {entry.data.trace_type} · {"##{entry.data.sequence_number}"}
                </p>
              </div>
              <span class="shrink-0 text-xs text-text-quaternary">
                {format_timeline_timestamp(entry.timestamp)}
              </span>
            </div>
            <p
              :if={entry.data.error_message not in [nil, ""]}
              class="text-xs text-red-300"
            >
              {entry.data.error_message}
            </p>
            <details
              :if={entry.data.tool_result not in [nil, ""]}
              class="mt-2 rounded border border-border/50 bg-canvas px-2 py-1 text-xs text-text-tertiary"
            >
              <summary class="cursor-pointer text-text-quaternary">Show raw tool result</summary>
              <p class="mt-2 whitespace-pre-wrap">{entry.data.tool_result}</p>
            </details>
          </div>

          <div
            :if={
              entry.type not in [:comment, :run, :interaction, :work_product, :tool_call_trace]
            }
            class="text-xs text-text-quaternary"
          >
            Unknown entry type
          </div>
        </div>
      </div>
    </div>
    """
  end
end
