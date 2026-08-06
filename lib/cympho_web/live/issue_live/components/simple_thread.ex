defmodule CymphoWeb.IssueLive.Show.SimpleThread do
  @moduledoc """
  Simple-mode issue thread: proof chips (latest run + work products + PR),
  chronological comments, and pending interaction cards with Confirm /
  Reject / Respond wired to the parent LiveView's existing resolve events.

  Gate CTAs for attach-proof / set-PR stay here so Simple mode never depends
  on Advanced-only review panels. Forms open via parent LiveView events.

  Gated with `ui-simple-only` so Advanced mode keeps using the full
  activity timeline. Composer stays outside this component (below).
  """
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers,
    only: [
      format_timeline_timestamp: 1,
      format_work_product_kind: 1,
      latest_run_brief: 1,
      run_status_label: 1,
      runtime_run_status_class: 1
    ]

  attr :issue, :map, required: true
  attr :timeline, :list, required: true
  attr :runs, :list, default: []
  attr :work_products, :list, default: []
  attr :all_agents, :list, default: []
  attr :gate_actions, :list, default: []

  def simple_thread(assigns) do
    pr_url = Cympho.Issues.Issue.pr_url(assigns.issue, assigns.issue.project)

    assigns =
      assigns
      |> assign(:thread_entries, simple_thread_entries(assigns.timeline))
      |> assign(:latest_run, List.first(List.wrap(assigns.runs)))
      |> assign(:proof_products, Enum.take(List.wrap(assigns.work_products), 5))
      |> assign(:pr_url, pr_url)
      |> assign(:proof_gate_actions, simple_proof_gate_actions(assigns.gate_actions))

    ~H"""
    <div id="issue-simple-thread" class="ui-simple-only space-y-4 px-4 pb-2 lg:px-6">
      <section
        id="issue-simple-proof"
        data-testid="issue-simple-proof"
        class="rounded-xl border border-border bg-panel/60 p-3"
      >
        <div class="flex items-center justify-between gap-2">
          <h2 class="text-xs font-510 uppercase tracking-[0.08em] text-text-tertiary">
            Proof
          </h2>
          <span class="text-[11px] text-text-quaternary">
            Latest run and deliverables
          </span>
        </div>
        <div class="mt-2 flex flex-wrap items-center gap-2">
          <div
            data-testid="issue-simple-proof-run"
            class={[
              "inline-flex max-w-full items-center gap-1.5 rounded-full border px-2.5 py-1 text-xs font-510",
              (@latest_run && runtime_run_status_class(@latest_run.status)) ||
                "border-hairline bg-surface-1 text-ink-tertiary"
            ]}
          >
            <span class="shrink-0">
              {if @latest_run,
                do: run_status_label(@latest_run.status),
                else: "No run yet"}
            </span>
            <span
              :if={@latest_run}
              class="min-w-0 truncate font-normal opacity-80"
            >
              {latest_run_brief(@latest_run)}
            </span>
          </div>
          <a
            :if={@pr_url}
            href={@pr_url}
            target="_blank"
            rel="noopener noreferrer"
            data-testid="issue-simple-proof-pr"
            class="inline-flex max-w-[16rem] items-center gap-1.5 rounded-full border border-emerald-500/30 bg-emerald-500/10 px-2.5 py-1 text-xs font-510 text-emerald-200 transition-colors hover:bg-emerald-500/15"
          >
            <span class="shrink-0 uppercase opacity-70">PR</span>
            <span class="min-w-0 truncate">{pr_chip_label(@pr_url, @issue)}</span>
            <span class="hero-arrow-top-right-on-square-mini h-3 w-3 shrink-0 opacity-70"></span>
          </a>
          <span
            :if={Enum.empty?(@proof_products) and is_nil(@pr_url)}
            data-testid="issue-simple-proof-empty-products"
            class="inline-flex items-center rounded-full border border-dashed border-border px-2.5 py-1 text-xs text-text-quaternary"
          >
            No work products yet
          </span>
          <a
            :for={wp <- @proof_products}
            :if={proof_product_href(wp)}
            href={proof_product_href(wp)}
            target="_blank"
            rel="noopener noreferrer"
            data-testid="issue-simple-proof-product"
            class="inline-flex max-w-[16rem] items-center gap-1.5 rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-xs text-brand transition-colors hover:bg-brand/15"
          >
            <span class="shrink-0 uppercase opacity-70">
              {format_work_product_kind(wp.kind)}
            </span>
            <span class="min-w-0 truncate font-510">{wp.title}</span>
            <span class="hero-arrow-top-right-on-square-mini h-3 w-3 shrink-0 opacity-70"></span>
          </a>
          <span
            :for={wp <- @proof_products}
            :if={!proof_product_href(wp)}
            data-testid="issue-simple-proof-product"
            class="inline-flex max-w-[16rem] items-center gap-1.5 rounded-full border border-brand/25 bg-brand/10 px-2.5 py-1 text-xs text-brand"
          >
            <span class="shrink-0 uppercase opacity-70">
              {format_work_product_kind(wp.kind)}
            </span>
            <span class="min-w-0 truncate font-510">{wp.title}</span>
          </span>
        </div>

        <div
          :if={!Enum.empty?(@proof_gate_actions)}
          data-testid="issue-simple-proof-actions"
          class="mt-3 flex flex-wrap items-center gap-2 border-t border-border/60 pt-3"
        >
          <button
            :for={action <- @proof_gate_actions}
            type="button"
            phx-click="resolve_review_gate"
            phx-value-action={action.action}
            data-testid={"issue-simple-gate-#{action.action}"}
            class="rounded-md border border-amber-500/30 bg-panel px-2.5 py-1.5 text-xs font-510 text-amber-100 transition-colors hover:bg-amber-500/15 hover:text-amber-50"
          >
            {simple_gate_label(action)}
          </button>
        </div>
      </section>

      <section data-testid="issue-simple-thread-list" class="space-y-3">
        <div class="flex items-center justify-between gap-2">
          <h2 class="text-sm font-510 text-text-primary">Thread</h2>
          <span class="text-[11px] text-text-quaternary">
            {length(@thread_entries)} {if length(@thread_entries) == 1,
              do: "entry",
              else: "entries"}
          </span>
        </div>

        <div
          :if={Enum.empty?(@thread_entries)}
          class="rounded-lg border border-dashed border-border bg-subtle px-4 py-8 text-center text-sm text-text-tertiary"
        >
          No comments yet. Use the box below to leave a note.
        </div>

        <div
          :for={entry <- @thread_entries}
          id={"simple-thread-#{entry.type}-#{entry.id}"}
          data-testid={"simple-entry-#{entry.type}"}
          class="space-y-2"
        >
          <.simple_comment
            :if={entry.type == :comment}
            comment={entry.data}
            all_agents={@all_agents}
            timestamp={entry.timestamp}
          />
          <.simple_interaction
            :if={entry.type == :interaction}
            interaction={entry.data}
            timestamp={entry.timestamp}
          />
        </div>
      </section>
    </div>
    """
  end

  attr :comment, :map, required: true
  attr :all_agents, :list, default: []
  attr :timestamp, :any, default: nil

  defp simple_comment(assigns) do
    ~H"""
    <article
      data-testid="simple-comment"
      class="rounded-lg border border-border/70 bg-surface p-3"
    >
      <div
        :if={@comment.author_type != "system"}
        class="mb-1.5 flex items-center justify-between gap-2"
      >
        <div class="flex min-w-0 items-center gap-2">
          <span class="truncate text-xs font-510 text-text-secondary">
            {comment_author_label(@comment, @all_agents)}
          </span>
          <span
            :if={@comment.author_type == "agent"}
            class="rounded bg-brand/10 px-1.5 py-0.5 text-[10px] text-brand"
          >
            Agent
          </span>
        </div>
        <span class="shrink-0 text-xs text-text-quaternary">
          {format_timeline_timestamp(@timestamp || @comment.inserted_at)}
        </span>
      </div>
      <p
        data-testid="simple-comment-body"
        class={
          if @comment.author_type == "system",
            do: "text-xs text-text-quaternary",
            else: "whitespace-pre-wrap text-sm text-text-secondary"
        }
      >
        {@comment.body}
      </p>
    </article>
    """
  end

  attr :interaction, :map, required: true
  attr :timestamp, :any, default: nil

  defp simple_interaction(assigns) do
    assigns =
      assigns
      |> assign(:pending?, assigns.interaction.status == :pending)
      |> assign(:kind_label, interaction_kind_label(assigns.interaction.kind))

    ~H"""
    <article
      id={"simple-interaction-#{@interaction.id}"}
      data-testid="simple-interaction"
      data-interaction-id={@interaction.id}
      data-interaction-kind={to_string(@interaction.kind)}
      data-interaction-status={to_string(@interaction.status)}
      class={[
        "space-y-3 rounded-lg border p-4",
        if(@pending?,
          do: "border-accent/35 bg-surface shadow-[inset_2px_0_0_0_var(--color-primary)]",
          else: "border-border/60 bg-surface/70"
        )
      ]}
    >
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="text-xs font-510 text-accent">{@kind_label}</span>
          <.badge variant="status" value={to_string(@interaction.status)} />
        </div>
        <span class="text-xs text-text-quaternary">
          {format_timeline_timestamp(@timestamp || @interaction.inserted_at)}
        </span>
      </div>

      <div :if={@interaction.kind == :suggest_tasks} class="space-y-2">
        <p class="text-sm text-text-secondary">
          {Map.get(@interaction.payload, "message", "The agent suggests the following tasks:")}
        </p>
        <div
          :for={{task, idx} <- Enum.with_index(Map.get(@interaction.payload, "tasks", []))}
          class="rounded-lg bg-subtle p-2"
        >
          <p class="text-sm font-510 text-text-primary">
            <span class="text-text-quaternary">{idx + 1}.</span>
            {Map.get(task, "title", "Untitled")}
          </p>
          <p :if={Map.get(task, "description")} class="mt-0.5 text-xs text-text-tertiary">
            {Map.get(task, "description")}
          </p>
        </div>
        <div
          :if={@pending?}
          data-testid="simple-interaction-resolve"
          class="flex flex-wrap items-center gap-2 pt-1"
        >
          <.button
            type="button"
            size="sm"
            phx-click="resolve_interaction"
            phx-value-id={@interaction.id}
            phx-value-status="accepted"
          >
            Accept Tasks
          </.button>
          <.button
            type="button"
            size="sm"
            variant="ghost"
            phx-click="resolve_interaction"
            phx-value-id={@interaction.id}
            phx-value-status="rejected"
          >
            Reject
          </.button>
        </div>
      </div>

      <div :if={@interaction.kind == :ask_user_questions} class="space-y-3">
        <p class="text-sm text-text-secondary">
          {Map.get(@interaction.payload, "message", "The agent has questions:")}
        </p>
        <div
          :for={{q, idx} <- Enum.with_index(Map.get(@interaction.payload, "questions", []))}
          class="space-y-1"
        >
          <p class="text-sm text-text-primary">
            <span class="text-text-quaternary">{idx + 1}.</span>
            {Map.get(q, "question", "N/A")}
          </p>
        </div>
        <div :if={Map.get(@interaction.payload, "response")} class="rounded-lg bg-subtle p-2">
          <p class="text-sm text-text-secondary">{Map.get(@interaction.payload, "response")}</p>
        </div>
        <div :if={@pending?} data-testid="simple-interaction-resolve" class="pt-1">
          <form
            id={"simple-respond-form-#{@interaction.id}"}
            phx-submit="respond_questions"
            class="space-y-2"
          >
            <input type="hidden" name="_id" value={@interaction.id} />
            <textarea
              name="response"
              placeholder="Type your response..."
              data-testid="simple-interaction-response"
              class="min-h-[60px] w-full resize-y rounded-lg border border-border bg-surface px-3 py-2 text-sm text-text-primary transition-colors placeholder:text-text-quaternary focus:border-accent focus:outline-none focus:ring-2 focus:ring-accent/30"
              required
            ></textarea>
            <.button type="submit" size="sm">Respond</.button>
          </form>
        </div>
      </div>

      <div :if={@interaction.kind == :request_confirmation} class="space-y-2">
        <p class="text-sm text-text-secondary">
          {Map.get(@interaction.payload, "message", "Please confirm:")}
        </p>
        <div
          :if={Map.get(@interaction.payload, "details")}
          class="rounded-lg bg-subtle p-2 text-xs text-text-tertiary"
        >
          {Map.get(@interaction.payload, "details")}
        </div>
        <div
          :if={@pending?}
          data-testid="simple-interaction-resolve"
          class="flex flex-wrap items-center gap-2 pt-1"
        >
          <.button
            type="button"
            size="sm"
            phx-click="resolve_interaction"
            phx-value-id={@interaction.id}
            phx-value-status="accepted"
          >
            Confirm
          </.button>
          <.button
            type="button"
            size="sm"
            variant="ghost"
            phx-click="resolve_interaction"
            phx-value-id={@interaction.id}
            phx-value-status="rejected"
          >
            Reject
          </.button>
        </div>
      </div>
    </article>
    """
  end

  defp simple_thread_entries(timeline) do
    timeline
    |> List.wrap()
    |> Enum.filter(&(&1.type in [:comment, :interaction]))
  end

  defp comment_author_label(%{author_type: "agent", author_id: author_id}, agents) do
    case Enum.find(agents, &(&1.id == author_id)) do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Agent"
    end
  end

  defp comment_author_label(%{author_type: "system"}, _agents), do: "System"

  defp comment_author_label(%{author_id: author_id}, _agents) when is_binary(author_id),
    do: author_id

  defp comment_author_label(_, _), do: "User"

  defp interaction_kind_label(:suggest_tasks), do: "Suggested Tasks"
  defp interaction_kind_label(:ask_user_questions), do: "Questions"
  defp interaction_kind_label(:request_confirmation), do: "Confirmation Request"
  defp interaction_kind_label(_), do: "Interaction"

  defp simple_proof_gate_actions(actions) do
    actions
    |> List.wrap()
    |> Enum.filter(fn action ->
      action.type == :event and action.action in ["work_product", "code_reference"] and
        Map.get(action, :enabled?, true)
    end)
    |> Enum.uniq_by(& &1.action)
  end

  defp simple_gate_label(%{action: "work_product"}), do: "Attach proof"
  defp simple_gate_label(%{action: "code_reference"}), do: "Set PR"
  defp simple_gate_label(%{label: label}) when is_binary(label), do: label
  defp simple_gate_label(_), do: "Resolve"

  defp proof_product_href(%{url: url}) when is_binary(url) and url != "", do: url
  defp proof_product_href(_), do: nil

  defp pr_chip_label(_url, %{github_pr_number: n}) when is_integer(n) and n > 0, do: "##{n}"
  defp pr_chip_label(url, _issue) when is_binary(url), do: truncate_url(url)
  defp pr_chip_label(_, _), do: "Pull request"

  defp truncate_url(url) when is_binary(url) do
    if String.length(url) > 36, do: String.slice(url, 0, 33) <> "…", else: url
  end
end
