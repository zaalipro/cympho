defmodule CymphoWeb.IssueLive.Show.Description do
  @moduledoc """
  Stateless function component for the issue description card. Renders
  either a read-only description with an inline edit affordance, or a
  textarea edit form when `editing == "description"`.

  Events (`start_editing`, `save_description`, `cancel_editing`) bubble
  to the parent LiveView since the parent owns the `editing` assign and
  the mutation flow.
  """
  use CymphoWeb, :html

  attr :issue, :map, required: true
  attr :editing, :any, default: nil
  attr :description_draft, :string, default: nil
  attr :delivery_brief_readiness, :map, default: nil

  def description(assigns) do
    ~H"""
    <div id="issue-description" class="px-4 lg:px-6 pb-5 scroll-mt-4">
      <div
        :if={@editing != "description"}
        class={description_shell_class(@issue)}
      >
        <div class="flex items-start gap-3">
          <div :if={@issue.description not in [nil, ""]} class="min-w-0 flex-1">
            <p
              :if={swarm_issue?(@issue)}
              class="mb-2 font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90"
            >
              Owner brief
            </p>
            <p class="ui-simple-only max-w-[70ch] text-sm leading-6 text-ink-muted">
              {compact_description(@issue.description, simple_description_limit(@issue))}
            </p>
            <p class={["ui-advanced-only", description_text_class(@issue)]}>
              {@issue.description}
            </p>
          </div>
          <button
            :if={@issue.description in [nil, ""]}
            type="button"
            phx-click="start_editing"
            phx-value-field="description"
            class="flex-1 text-left font-serif text-sm italic text-ink-tertiary hover:text-ink-muted transition-colors"
          >
            Add a description — give the next agent something to work from…
          </button>
          <button
            :if={@issue.description not in [nil, ""]}
            type="button"
            phx-click="start_editing"
            phx-value-field="description"
            class="shrink-0 opacity-0 group-hover:opacity-100 text-ink-tertiary hover:text-ink-muted transition-all"
            aria-label="Edit description"
          >
            <.icon name="hero-pencil-mini" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <div
        :if={delivery_brief_needs_repair?(@delivery_brief_readiness) and @editing != "description"}
        id="issue-delivery-brief-repair"
        class="mt-3 rounded-md border border-amber-500/25 bg-amber-500/[0.08] px-3 py-2.5"
      >
        <div class="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
          <div class="min-w-0">
            <p class="text-[10px] font-510 uppercase tracking-[0.1em] text-amber-300">
              The brief needs more detail
            </p>
            <p class="mt-1 text-sm leading-5 text-amber-100">
              Agents need a bit more to run with: what to do, what done looks like, and how to prove it.
            </p>
            <p class="mt-1 text-caption leading-4 text-amber-100/75">
              {@delivery_brief_readiness.next_prompt}
            </p>
          </div>
          <div class="flex shrink-0 flex-wrap gap-2">
            <button
              type="button"
              data-copy-text={@delivery_brief_readiness.repair_scaffold}
              data-copy-label="Copy template"
              data-copy-success-label="Copied"
              class="inline-flex items-center justify-center rounded-md border border-amber-500/25 bg-panel px-2.5 py-1.5 text-xs font-510 text-amber-100 transition hover:bg-amber-500/15"
            >
              Copy template
            </button>
            <button
              type="button"
              phx-click="draft_delivery_brief_repair"
              class="inline-flex items-center justify-center rounded-md border border-amber-500/25 bg-amber-500/10 px-2.5 py-1.5 text-xs font-510 text-amber-100 transition hover:bg-amber-500/15"
            >
              Use template
            </button>
          </div>
        </div>
        <details class="group/scaffold mt-2">
          <summary class="inline-flex cursor-pointer select-none list-none items-center gap-1 text-[11px] font-510 text-amber-100/80 transition hover:text-amber-50 [&::-webkit-details-marker]:hidden">
            <.icon
              name="hero-chevron-down-mini"
              class="h-3.5 w-3.5 transition-transform group-open/scaffold:rotate-180"
            /> Preview template
          </summary>
          <pre class="mt-2 max-h-64 overflow-auto whitespace-pre-wrap break-words rounded border border-amber-500/15 bg-canvas px-3 py-2 font-mono text-[11px] leading-5 text-amber-100/90"><%= @delivery_brief_readiness.repair_scaffold %></pre>
        </details>
      </div>

      <form
        :if={@editing == "description"}
        phx-submit="save_description"
        class="rounded-lg border border-hairline bg-surface-1 p-3 space-y-3 transition-shadow focus-within:border-brand/40 focus-within:shadow-[0_0_0_3px_rgb(217_119_87_/_0.12)]"
      >
        <textarea
          name="description"
          class="w-full bg-transparent text-body leading-relaxed text-ink placeholder:text-ink-tertiary focus:outline-none min-h-[140px] resize-y"
          autofocus
        ><%= @description_draft || @issue.description %></textarea>
        <div class="flex items-center gap-2 border-t border-hairline pt-3">
          <.button type="submit" size="sm">Save</.button>
          <.button type="button" variant="ghost" size="sm" phx-click="cancel_editing">
            Cancel
          </.button>
        </div>
      </form>
    </div>
    """
  end

  defp delivery_brief_needs_repair?(%{status: status, repair_scaffold: scaffold})
       when status in [:thin, :draft] and is_binary(scaffold) and scaffold != "",
       do: true

  defp delivery_brief_needs_repair?(_readiness), do: false

  defp description_shell_class(issue) do
    if swarm_issue?(issue) do
      "group border-y border-hairline bg-surface-1/20 px-1 py-3.5 hover:border-hairline-strong transition-colors duration-100"
    else
      "group rounded-lg border border-hairline bg-surface-1/40 px-4 py-3.5 hover:border-hairline-strong transition-colors duration-100"
    end
  end

  defp description_text_class(issue) do
    if swarm_issue?(issue) do
      "max-w-[72ch] whitespace-pre-wrap text-sm leading-6 text-ink-muted"
    else
      "max-w-[72ch] whitespace-pre-wrap text-body leading-relaxed text-ink-muted"
    end
  end

  defp swarm_issue?(%{origin_type: origin}) when origin in ["swarm_worker", "swarm_cto_review"],
    do: true

  defp swarm_issue?(%{monitor_state: monitor_state}) when is_map(monitor_state) do
    monitor_state
    |> Map.get("swarm", Map.get(monitor_state, :swarm))
    |> swarm_state?()
  end

  defp swarm_issue?(_issue), do: false

  defp swarm_state?(%{"enabled" => enabled}) when enabled in [true, "true"], do: true
  defp swarm_state?(%{enabled: enabled}) when enabled in [true, "true"], do: true
  defp swarm_state?(%{"role" => role}) when role in ["worker", "cto_synthesis"], do: true
  defp swarm_state?(%{role: role}) when role in ["worker", "cto_synthesis"], do: true
  defp swarm_state?(_), do: false

  defp simple_description_limit(issue) do
    if swarm_issue?(issue), do: 260, else: 220
  end

  defp compact_description(description, max) do
    description
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate(max)
  end

  defp truncate(text, max) when byte_size(text) <= max, do: text

  defp truncate(text, max) do
    text
    |> String.slice(0, max)
    |> String.trim_trailing()
    |> Kernel.<>("...")
  end
end
