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

  def description(assigns) do
    ~H"""
    <div class="px-4 lg:px-6 pb-5">
      <div
        :if={@editing != "description"}
        class="group rounded-lg border border-hairline bg-surface-1/40 px-4 py-3.5 hover:border-hairline-strong transition-colors duration-100"
      >
        <div class="flex items-start gap-3">
          <p
            :if={@issue.description not in [nil, ""]}
            class="flex-1 text-body text-ink-muted whitespace-pre-wrap leading-relaxed"
          >
            {@issue.description}
          </p>
          <button
            :if={@issue.description in [nil, ""]}
            type="button"
            phx-click="start_editing"
            phx-value-field="description"
            class="flex-1 text-left text-caption text-ink-tertiary hover:text-ink-muted transition-colors"
          >
            Add description…
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

      <form
        :if={@editing == "description"}
        phx-submit="save_description"
        class="rounded-lg border border-hairline bg-surface-1 p-3 space-y-3"
      >
        <textarea
          name="description"
          class="w-full bg-transparent text-body text-ink placeholder:text-ink-tertiary focus:outline-none min-h-[140px] resize-y"
          autofocus
        ><%= @issue.description %></textarea>
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
end
