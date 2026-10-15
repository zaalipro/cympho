defmodule CymphoWeb.DocsLive.Components.SearchModal do
  @moduledoc """
  Instant in-app search dialog for Cympho documentation with keyboard navigation.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: CymphoWeb.Endpoint, router: CymphoWeb.Router

  attr :open, :boolean, default: false
  attr :query, :string, default: ""
  attr :results, :list, default: []
  attr :selected_index, :integer, default: 0

  def search_modal(assigns) do
    ~H"""
    <div
      :if={@open}
      id="docs-search-modal"
      class="fixed inset-0 z-[60] flex items-start justify-center pt-16 sm:pt-24 p-4 bg-black/60 backdrop-blur-sm transition-opacity"
      phx-window-keydown="search_keydown"
    >
      <div
        class="fixed inset-0"
        phx-click="close_search"
        aria-hidden="true"
      >
      </div>

      <div class="relative w-full max-w-2xl rounded-2xl bg-surface-2 border border-hairline shadow-dialog overflow-hidden z-10">
        <!-- Search Input Bar -->
        <div class="flex items-center gap-3 px-4 py-3 border-b border-hairline bg-surface-1">
          <svg
            class="w-5 h-5 text-ink-subtle shrink-0"
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
            />
          </svg>
          <form phx-change="search" phx-submit="search_submit" class="flex-1">
            <input
              id="docs-search-input"
              type="text"
              name="query"
              value={@query}
              placeholder="Search guides, concepts, MCP tools, and APIs..."
              class="w-full bg-transparent border-0 p-0 text-sm text-ink placeholder:text-ink-tertiary focus:ring-0 focus:outline-none"
              autocomplete="off"
              autofocus
              phx-debounce="100"
            />
          </form>
          <button
            type="button"
            phx-click="close_search"
            class="p-1 rounded-md text-ink-tertiary hover:text-ink hover:bg-surface-3 transition-colors"
            aria-label="Close search"
          >
            <kbd class="kbd text-[11px]">ESC</kbd>
          </button>
        </div>
        
    <!-- Search Results Panel -->
        <div class="max-h-[60vh] overflow-y-auto p-2">
          <%= cond do %>
            <% @query == "" -> %>
              <div class="p-8 text-center text-ink-subtle space-y-2">
                <p class="text-sm font-510 text-ink-muted">Quick Documentation Search</p>
                <p class="text-xs text-ink-tertiary">
                  Search across all 8 tracks, 9 built-in MCP tools, REST endpoints, and workflows.
                </p>
                <div class="pt-3 flex flex-wrap justify-center gap-1.5">
                  <button
                    type="button"
                    phx-click="search_suggest"
                    phx-value-query="mcp"
                    class="px-2 py-1 rounded bg-surface-3 hover:bg-surface-4 text-[11px] text-ink-muted border border-hairline"
                  >
                    mcp
                  </button>
                  <button
                    type="button"
                    phx-click="search_suggest"
                    phx-value-query="swarm mode"
                    class="px-2 py-1 rounded bg-surface-3 hover:bg-surface-4 text-[11px] text-ink-muted border border-hairline"
                  >
                    swarm mode
                  </button>
                  <button
                    type="button"
                    phx-click="search_suggest"
                    phx-value-query="worktrees"
                    class="px-2 py-1 rounded bg-surface-3 hover:bg-surface-4 text-[11px] text-ink-muted border border-hairline"
                  >
                    worktrees
                  </button>
                  <button
                    type="button"
                    phx-click="search_suggest"
                    phx-value-query="board approvals"
                    class="px-2 py-1 rounded bg-surface-3 hover:bg-surface-4 text-[11px] text-ink-muted border border-hairline"
                  >
                    board approvals
                  </button>
                </div>
              </div>
            <% @results == [] -> %>
              <div class="p-8 text-center text-ink-subtle space-y-2">
                <p class="text-sm font-510 text-ink">No documentation matches found</p>
                <p class="text-xs text-ink-tertiary">
                  No articles matched "<span class="text-ink-muted">{@query}</span>". Try different keywords or browse topics in the sidebar.
                </p>
              </div>
            <% true -> %>
              <div class="space-y-1">
                <%= for {result, idx} <- Enum.with_index(@results) do %>
                  <% selected? = idx == @selected_index %>
                  <.link
                    patch={~p"/docs/#{result.doc.topic_slug}/#{result.doc.section_slug}"}
                    phx-click="close_search"
                    class={[
                      "block p-3 rounded-xl border transition-colors",
                      if(selected?,
                        do: "bg-surface-3 border-brand/40 shadow-sm",
                        else:
                          "bg-surface-2 border-transparent hover:bg-surface-3 hover:border-hairline"
                      )
                    ]}
                    id={"search-result-#{idx}"}
                  >
                    <div class="flex items-center justify-between gap-2">
                      <span class="font-serif text-[14px] font-510 text-ink">
                        {result.doc.title}
                      </span>
                      <span class="text-[11px] text-brand/80 font-510 uppercase tracking-wider shrink-0">
                        {String.replace(result.doc.topic_slug, "-", " ")}
                      </span>
                    </div>
                    <p class="mt-1 text-xs text-ink-muted line-clamp-2 leading-relaxed">
                      {result.snippet}
                    </p>
                  </.link>
                <% end %>
              </div>
          <% end %>
        </div>
        
    <!-- Footer / Keyboard hint -->
        <div class="px-4 py-2 border-t border-hairline bg-surface-1 flex items-center justify-between text-[11px] text-ink-tertiary">
          <div class="flex items-center gap-3">
            <span class="flex items-center gap-1">
              <kbd class="kbd text-[10px]">↑</kbd>
              <kbd class="kbd text-[10px]">↓</kbd>
              <span>navigate</span>
            </span>
            <span class="flex items-center gap-1">
              <kbd class="kbd text-[10px]">↵</kbd>
              <span>open</span>
            </span>
            <span class="flex items-center gap-1">
              <kbd class="kbd text-[10px]">ESC</kbd>
              <span>close</span>
            </span>
          </div>
          <div>
            <span>{length(@results)} {if length(@results) == 1, do: "result", else: "results"}</span>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
