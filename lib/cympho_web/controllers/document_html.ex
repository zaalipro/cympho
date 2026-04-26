defmodule CymphoWeb.DocumentHTML do
  use CymphoWeb, :html

  def render("index.html", assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-text-primary">Document Revisions</h1>
          <p class="text-text-tertiary mt-1">
            {@document.title}
          </p>
        </div>
        <.link
          navigate={~p"/issues/#{@document.issue_id}"}
          class="text-text-quaternary hover:text-text-secondary transition-colors"
        >
          &larr; Back to Issue
        </.link>
      </div>

      <div class="space-y-2 max-h-[600px] overflow-y-auto">
        <%= for revision <- @revisions do %>
          <div class="flex items-start gap-3 p-4 rounded-lg bg-white/[0.02] border border-border hover:bg-white/[0.04] transition-colors">
            <div class="flex-shrink-0">
              <div class="w-10 h-10 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-semibold">
                {String.first(revision.author_type || "A")}
              </div>
            </div>

            <div class="flex-1 min-w-0">
              <div class="flex items-center gap-2 mb-1">
                <span class="text-sm font-medium text-text-primary">
                  Revision {revision.revision_number}
                </span>
                <span class="text-xs text-text-quaternary">
                  {format_datetime(revision.inserted_at)}
                </span>
              </div>

              <h3 class="text-base font-semibold text-text-primary mb-1">{revision.title}</h3>

              <p :if={revision.change_summary} class="text-sm text-text-tertiary mb-2">
                {revision.change_summary}
              </p>
            </div>

            <div class="flex-shrink-0 flex items-center gap-2">
              <span class="text-xs text-text-quaternary">
                Revision {revision.revision_number}
              </span>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  def render("show_revision.html", assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-text-primary">Document Revision</h1>
          <p class="text-text-tertiary mt-1">
            {@revision.title} (Revision {@revision.revision_number})
          </p>
        </div>
        <.link
          navigate={~p"/issues/#{@document.issue_id}"}
          class="text-text-quaternary hover:text-text-secondary transition-colors"
        >
          &larr; Back to Issue
        </.link>
      </div>

      <div class="bg-white/[0.02] rounded-lg border border-border p-6">
        <div class="flex items-center gap-3 mb-4 pb-4 border-b border-border">
          <div class="w-10 h-10 rounded-full bg-blue-500/20 text-blue-400 flex items-center justify-center text-sm font-semibold">
            {String.first(@revision.author_type || "A")}
          </div>
          <div>
            <p class="text-sm font-medium text-text-primary">
              {@revision.author_type || "System"}
            </p>
            <p class="text-xs text-text-quaternary">
              {format_datetime(@revision.inserted_at)}
            </p>
          </div>
        </div>

        <p :if={@revision.change_summary} class="text-sm text-text-tertiary mb-4">
          {@revision.change_summary}
        </p>

        <div class="prose prose-invert max-w-none">
          <pre class="whitespace-pre-wrap text-text-secondary font-mono text-sm"><%= @revision.body %></pre>
        </div>
      </div>
    </div>
    """
  end

  def format_datetime(datetime) when not is_nil(datetime) do
    datetime
    |> DateTime.to_string()
    |> String.replace("Z", "")
    |> String.slice(0, 19)
  end

  def format_datetime(_), do: "N/A"
end
