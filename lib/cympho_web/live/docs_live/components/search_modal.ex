defmodule CymphoWeb.DocsLive.Components.SearchModal do
  @moduledoc """
  Instant in-app search dialog for Cympho documentation with keyboard navigation.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: CymphoWeb.Endpoint, router: CymphoWeb.Router

  import CymphoWeb.CoreComponents, only: [modal: 1]
  import CymphoWeb.Components.R3, only: [chip: 1, quiet_empty: 1, search_capsule: 1]

  alias Phoenix.LiveView.JS

  attr :open, :boolean, default: false
  attr :query, :string, default: ""
  attr :results, :list, default: []
  attr :selected_index, :integer, default: 0

  def search_modal(assigns) do
    ~H"""
    <.modal
      :if={@open}
      id="docs-search-modal"
      show
      title="Search the documentation"
      on_cancel={JS.push("close_search")}
    >
      <div class="dc-search" phx-window-keydown="search_keydown">
        <form phx-change="search" phx-submit="search_submit">
          <.search_capsule
            id="docs-search-input"
            label="Search the documentation"
            name="query"
            value={@query}
            placeholder="Guides, concepts, MCP tools and APIs"
            autofocus
            phx-debounce="100"
          />
        </form>

        <%= cond do %>
          <% @query == "" -> %>
            <div class="dc-try">
              <p class="gl-sub">
                Search across all 8 tracks, 9 built-in MCP tools, REST endpoints, and workflows.
              </p>
              <div class="chips">
                <.chip
                  :for={suggestion <- ["mcp", "swarm mode", "worktrees", "board approvals"]}
                  phx-click="search_suggest"
                  phx-value-query={suggestion}
                >
                  {suggestion}
                </.chip>
              </div>
            </div>
          <% @results == [] -> %>
            <.quiet_empty title="No documentation matches found">
              No articles matched “{@query}”. Try different keywords or browse the topics.
            </.quiet_empty>
          <% true -> %>
            <ul class="dc-hits">
              <li :for={{result, idx} <- Enum.with_index(@results)}>
                <.link
                  patch={~p"/docs/#{result.doc.topic_slug}/#{result.doc.section_slug}"}
                  phx-click="close_search"
                  id={"search-result-#{idx}"}
                  class="dc-hit"
                  aria-current={idx == @selected_index && "true"}
                >
                  <span class="dc-hit-t">
                    <span>{result.doc.title}</span><span class="tag">{String.replace(result.doc.topic_slug, "-", " ")}</span>
                  </span>
                  <span class="dc-hit-s">{result.snippet}</span>
                </.link>
              </li>
            </ul>
        <% end %>
      </div>
      <:footer>
        <span class="dc-keys">
          <kbd>↑</kbd><kbd>↓</kbd> move <kbd>↵</kbd> open <kbd>Esc</kbd> close
        </span>
        <span class="meta">
          <span class="mono">{length(@results)}</span>
          {if length(@results) == 1, do: "result", else: "results"}
        </span>
      </:footer>
    </.modal>
    """
  end
end
