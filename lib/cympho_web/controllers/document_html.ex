<div class="space-y-6">
  <div class="flex items-center justify-between">
    <div>
      <h1 class="text-2xl font-bold text-text-primary">Document Revisions</h1>
      <p class="text-text-tertiary mt-1">
        <%= @document.title %>
      </p>
    </div>
    <.link
      navigate={~p"/issues/#{@document.issue_id}"}
      class="text-text-quaternary hover:text-text-secondary transition-colors"
    >
      ← Back to Issue
    </.link>
  </div>

  <div class="space-y-2 max-h-[600px] overflow-y-auto">
    <%= for revision <- @revisions do %>
      <div class="flex items-start gap-3 p-4 rounded-lg bg-white/[0.02] border border-border hover:bg-white/[0.04] transition-colors">
        <div class="flex-shrink-0">
          <div class="w-10 h-10 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-semibold">
            <%= String.first(revision.author_type || "A") %>
          </div>
        </div>

        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 mb-1">
            <span class="text-sm font-medium text-text-primary">
              Revision <%= revision.revision_number %>
            </span>
            <span class="text-xs text-text-quaternary">
              <%= format_datetime(revision.inserted_at) %>
            </span>
          </div>

          <h3 class="text-base font-semibold text-text-primary mb-1"><%= revision.title %></h3>

          <p :if={revision.change_summary} class="text-sm text-text-tertiary mb-2">
            <%= revision.change_summary %>
          </p>
        </div>

        <div class="flex-shrink-0 flex items-center gap-2">
          <.link
            navigate={~p"/issues/#{@document.issue_id}/documents/#{@document.key}/revisions/#{revision.id}"}
            class="text-sm px-3 py-1.5 rounded-md bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary transition-colors"
          >
            View
          </.link>

          <.link
            navigate={~p"/issues/#{@document.issue_id}/documents/#{@document.key}/revisions/#{revision.id}/diff"}
            class="text-sm px-3 py-1.5 rounded-md bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary transition-colors"
          >
            Compare
          </.link>

          <.link
            navigate={~p"/issues/#{@document.issue_id}/documents/#{@document.key}/rollback/#{revision.id}"}
            class="text-sm px-3 py-1.5 rounded-md bg-white/[0.05] hover:bg-white/[0.1] text-text-secondary transition-colors"
          >
            Rollback
          </.link>
        </div>
      </div>
    <% end %>
  </div>
</div>

<style>
  .diff-line-addition {
    background-color: rgba(34, 197, 94, 0.1);
    color: #4ade80;
  }

  .diff-line-deletion {
    background-color: rgba(239, 68, 68, 0.1);
    color: #f87171;
  }

  .diff-line-same {
    color: #a1a1aa;
  }
</style>

def render("show_revision.html", assigns) do
  ~H"""
  <div class="space-y-6">
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-2xl font-bold text-text-primary">Document Revision</h1>
        <p class="text-text-tertiary mt-1">
          <%= @revision.title %> (Revision <%= @revision.revision_number %>)
        </p>
      </div>
      <.link
        navigate={~p"/issues/#{@document.issue_id}/documents/#{@document.key}/revisions"}
        class="text-text-quaternary hover:text-text-secondary transition-colors"
      >
        ← Back to Revisions
      </.link>
    </div>

    <div class="bg-white/[0.02] rounded-lg border border-border p-6">
      <div class="flex items-center gap-3 mb-4 pb-4 border-b border-border">
        <div class="w-10 h-10 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-semibold">
          <%= String.first(@revision.author_type || "A") %>
        </div>
        <div>
          <p class="text-sm font-medium text-text-primary">
            <%= @revision.author_type || "System" %>
          </p>
          <p class="text-xs text-text-quaternary">
            <%= format_datetime(@revision.inserted_at) %>
          </p>
        </div>
      </div>

      <p :if={@revision.change_summary} class="text-sm text-text-tertiary mb-4">
        <%= @revision.change_summary %>
      </p>

      <div class="prose prose-invert max-w-none">
        <pre class="whitespace-pre-wrap text-text-secondary font-mono text-sm"><%= @revision.body %></pre>
      </div>
    </div>
  </div>
  """
end
