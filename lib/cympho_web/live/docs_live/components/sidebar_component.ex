defmodule CymphoWeb.DocsLive.Components.SidebarComponent do
  @moduledoc """
  Categorized docs sidebar sub-navigation rail with quick search trigger.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: CymphoWeb.Endpoint, router: CymphoWeb.Router

  attr :topics, :list, required: true
  attr :active_topic_slug, :string, required: true
  attr :active_section_slug, :string, required: true
  attr :mobile, :boolean, default: false

  def sidebar(assigns) do
    ~H"""
    <div class={[
      "flex flex-col h-full",
      if(@mobile, do: "w-full", else: "w-64 border-r border-hairline bg-surface-1 shrink-0")
    ]}>
      <!-- Search trigger header -->
      <div class="p-3 border-b border-hairline">
        <button
          type="button"
          phx-click="open_search"
          class="w-full flex items-center justify-between gap-2 px-3 py-2 rounded-lg bg-surface-2 hover:bg-surface-3 border border-hairline text-ink-subtle hover:text-ink text-xs transition-colors"
          aria-label="Search documentation"
        >
          <div class="flex items-center gap-2 truncate">
            <svg
              class="w-3.5 h-3.5 shrink-0 text-ink-tertiary"
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
            <span class="truncate">Search docs...</span>
          </div>
          <div class="flex items-center gap-1 shrink-0">
            <kbd class="kbd text-[10px]">⌘K</kbd>
            <kbd class="kbd text-[10px]">/</kbd>
          </div>
        </button>
      </div>
      
    <!-- Scrollable topic tree -->
      <nav class="flex-1 overflow-y-auto p-3 space-y-6" aria-label="Documentation Topics">
        <%= for topic <- @topics do %>
          <div class="space-y-1">
            <!-- Topic Header -->
            <div class="px-2 py-1 flex items-center gap-2">
              <span class="text-[11px] font-510 tracking-[0.06em] uppercase text-ink-tertiary">
                {topic.title}
              </span>
            </div>
            
    <!-- Topic Sections -->
            <ul class="space-y-0.5">
              <%= for section <- topic.sections do %>
                <% active? = topic.slug == @active_topic_slug and section.slug == @active_section_slug %>
                <li>
                  <.link
                    patch={~p"/docs/#{topic.slug}/#{section.slug}"}
                    class={[
                      "group flex items-center gap-2 px-2.5 py-1.5 rounded-md text-[13px] font-510 transition-colors",
                      if(active?,
                        do: "bg-brand/15 text-brand font-590 shadow-sm",
                        else: "text-ink-muted hover:text-ink hover:bg-surface-hover"
                      )
                    ]}
                    aria-current={if active?, do: "page", else: nil}
                  >
                    <span class={[
                      "w-1.5 h-1.5 rounded-full shrink-0 transition-colors",
                      if(active?, do: "bg-brand", else: "bg-transparent group-hover:bg-ink-tertiary")
                    ]}>
                    </span>
                    <span class="truncate">{section.title}</span>
                  </.link>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </nav>
    </div>
    """
  end
end
