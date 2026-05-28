defmodule CymphoWeb.IssueLive.Show.Comments do
  @moduledoc """
  Stateless function component for the sticky comment composer: template
  chips and the comment form. Events (`use_comment_template`,
  `add_comment`) bubble to the parent LiveView, which owns the form
  changeset and persistence.
  """
  use CymphoWeb, :html

  attr :comment_form, :any, required: true
  attr :comment_templates, :list, default: []

  def comments(assigns) do
    ~H"""
    <div id="issue-comments" class="p-4 lg:p-6 border-t border-border bg-surface/50">
      <div class="mb-2 text-xs font-510 uppercase tracking-wider text-text-secondary">
        Add Comment
      </div>
      <form id="comment-form" phx-submit="add_comment" class="space-y-3">
        <div class="flex flex-wrap gap-1.5">
          <button
            :for={template <- @comment_templates}
            type="button"
            phx-click="use_comment_template"
            phx-value-template={template.key}
            title={template.hint}
            class="inline-flex items-center gap-1 rounded-md border border-border bg-canvas px-2 py-1 text-[11px] font-510 text-text-tertiary transition-colors hover:border-brand/40 hover:bg-brand/10 hover:text-brand"
          >
            {template.label}
          </button>
        </div>
        <div class="flex gap-2">
          <div class="flex-1">
            <.input
              field={@comment_form[:body]}
              type="textarea"
              placeholder="Add a comment, or choose a template above..."
              class="min-h-[60px] max-h-[200px] resize-y"
              rows={2}
            />
          </div>
          <.button type="submit" class="self-end" aria-label="Send comment">
            <.icon name="hero-paper-airplane" class="w-4 h-4" />
            <span>Send</span>
          </.button>
        </div>
      </form>
    </div>
    """
  end
end
