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
    <div
      id="issue-comments"
      class="sticky-above-mobile-nav sticky z-20 border-t border-border bg-surface/95 p-4 backdrop-blur lg:p-6"
    >
      <form id="comment-form" phx-submit="add_comment" class="space-y-3">
        <div class="flex gap-2">
          <div class="flex-1 rounded-xl transition-shadow focus-within:shadow-[0_0_0_3px_rgb(217_119_87_/_0.14)]">
            <.input
              field={@comment_form[:body]}
              type="textarea"
              placeholder="Write a comment…"
              class="min-h-[60px] max-h-[200px] resize-y"
              rows={2}
            />
          </div>
          <div class="flex items-end gap-2">
            <details class="cympho-menu relative">
              <summary
                class="flex h-9 w-9 cursor-pointer list-none items-center justify-center rounded-lg border border-border bg-surface-2 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                aria-label="Comment templates"
                title="Comment templates"
              >
                <.icon name="hero-document-text-mini" class="h-4 w-4" />
              </summary>
              <div class="cympho-menu-panel absolute bottom-11 right-0 z-30 min-w-48 rounded-xl border border-border bg-panel p-1 shadow-dialog">
                <button
                  :for={template <- @comment_templates}
                  type="button"
                  phx-click="use_comment_template"
                  phx-value-template={template.key}
                  title={template.hint}
                  class="flex w-full items-center rounded-md px-2.5 py-2 text-left text-xs text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
                >
                  {template.label}
                </button>
              </div>
            </details>
            <.icon_action
              type="submit"
              icon="hero-paper-airplane-mini"
              label="Send comment"
              class="cta-glow border-brand bg-brand text-on-primary hover:bg-brand/90"
            />
          </div>
        </div>
      </form>
    </div>
    """
  end
end
