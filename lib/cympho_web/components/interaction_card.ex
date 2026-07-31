defmodule CymphoWeb.Components.InteractionCard do
  use Phoenix.Component
  import CymphoWeb.Components.Badge, only: [badge: 1]

  attr :interaction, :map, required: true
  attr :current_user_id, :string, default: nil

  def interaction_card(assigns) do
    assigns =
      assigns
      |> assign(:resolved?, assigns.interaction.status != :pending)
      |> assign(:kind_label, kind_label(assigns.interaction.kind))

    ~H"""
    <div
      id={"interaction-#{@interaction.id}"}
      class={[
        "card-lift bg-surface border rounded-xl p-4 space-y-3 shadow-card transition-colors",
        (@resolved? && "border-border") || "border-brand/25 hover:border-brand/40"
      ]}
    >
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-2">
          <span class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
            {@kind_label}
          </span>
          <.badge variant="status" value={to_string(@interaction.status)} />
        </div>
        <span class="text-xs text-text-quaternary">{@interaction.inserted_at}</span>
      </div>

      <div class="interaction-body">
        <%= case @interaction.kind do %>
          <% :suggest_tasks -> %>
            <.suggest_tasks_body interaction={@interaction} resolved={@resolved?} />
          <% :ask_user_questions -> %>
            <.ask_user_questions_body interaction={@interaction} resolved={@resolved?} />
          <% :request_confirmation -> %>
            <.request_confirmation_body interaction={@interaction} resolved={@resolved?} />
        <% end %>
      </div>
    </div>
    """
  end

  defp kind_label(:suggest_tasks), do: "Suggested Tasks"
  defp kind_label(:ask_user_questions), do: "Questions"
  defp kind_label(:request_confirmation), do: "Confirmation Request"

  attr :interaction, :map, required: true
  attr :resolved, :boolean, default: false

  def suggest_tasks_body(assigns) do
    tasks = Map.get(assigns.interaction.payload, "tasks", [])

    assigns =
      assigns
      |> assign(:tasks, tasks)

    ~H"""
    <div class="space-y-2">
      <p class="text-sm text-text-secondary">
        {Map.get(@interaction.payload, "message", "The agent suggests the following tasks:")}
      </p>
      <div
        :for={{task, idx} <- Enum.with_index(@tasks)}
        class="flex items-start gap-2 p-2 bg-subtle rounded-lg transition-shadow hover:shadow-[inset_2px_0_0_0_var(--color-primary)]"
      >
        <span class="text-xs text-text-quaternary mt-0.5 font-mono tabular-nums">{idx + 1}.</span>
        <div class="flex-1">
          <p class="text-sm text-text-primary font-510">{Map.get(task, "title", "Untitled")}</p>
          <p :if={Map.get(task, "description")} class="text-xs text-text-tertiary mt-0.5">
            {Map.get(task, "description")}
          </p>
        </div>
        <div :if={Map.get(task, "accepted")}>
          <span class="inline-flex items-center gap-1 rounded-full border border-emerald-500/25 bg-emerald-500/10 px-2 py-0.5 text-[11px] font-510 text-emerald-300">
            <span class="hero-check-mini h-3 w-3" aria-hidden="true"></span> Accepted
          </span>
        </div>
      </div>
    </div>
    """
  end

  attr :interaction, :map, required: true
  attr :resolved, :boolean, default: false

  def ask_user_questions_body(assigns) do
    questions = Map.get(assigns.interaction.payload, "questions", [])

    assigns =
      assigns
      |> assign(:questions, questions)

    ~H"""
    <div class="space-y-3">
      <p class="text-sm text-text-secondary">
        {Map.get(@interaction.payload, "message", "The agent has questions:")}
      </p>
      <div :for={{q, idx} <- Enum.with_index(@questions)} class="space-y-1">
        <p class="text-sm text-text-primary">
          <span class="text-text-quaternary">{idx + 1}.</span> {Map.get(q, "question", "N/A")}
        </p>
        <div :if={Map.get(q, "answer")} class="pl-4 text-sm text-accent">
          Answer: {Map.get(q, "answer")}
        </div>
      </div>
      <div :if={Map.get(@interaction.payload, "response")} class="mt-2 p-2 bg-subtle rounded-lg">
        <p class="text-sm text-text-secondary">{Map.get(@interaction.payload, "response")}</p>
      </div>
    </div>
    """
  end

  attr :interaction, :map, required: true
  attr :resolved, :boolean, default: false

  def request_confirmation_body(assigns) do
    assigns =
      assigns
      |> assign(:message, Map.get(assigns.interaction.payload, "message", "Please confirm:"))

    ~H"""
    <div class="space-y-2">
      <p class="text-sm text-text-secondary">{@message}</p>
      <div
        :if={Map.get(@interaction.payload, "details")}
        class="text-xs text-text-tertiary p-2 bg-subtle rounded-lg"
      >
        {Map.get(@interaction.payload, "details")}
      </div>
      <p
        :if={Map.has_key?(@interaction.payload, "target_revision_number")}
        class="text-xs text-text-quaternary"
      >
        Pinned to {Map.get(@interaction.payload, "target_document_title", "plan")} revision {Map.get(
          @interaction.payload,
          "target_revision_number"
        )}.
      </p>
    </div>
    """
  end
end
