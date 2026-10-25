defmodule CymphoWeb.DocsLive.Components.SidebarComponent do
  @moduledoc """
  The docs topic nav (the Settings section nav's look) with the search trigger.
  """
  use Phoenix.Component
  use Phoenix.VerifiedRoutes, endpoint: CymphoWeb.Endpoint, router: CymphoWeb.Router

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  attr :topics, :list, required: true
  attr :active_topic_slug, :string, required: true
  attr :active_section_slug, :string, required: true
  attr :mobile, :boolean, default: false

  def sidebar(assigns) do
    ~H"""
    <div class={["dc-side", @mobile && "m"]}>
      <button type="button" class="search dc-find" phx-click="open_search">
        <.r3_icon name="i-search" /><span>Search docs</span>
      </button>

      <nav class="dc-nav" aria-label="Documentation Topics">
        <div :for={topic <- @topics}>
          <p class="dc-g">{topic.title}</p>
          <ul>
            <li :for={section <- topic.sections}>
              <.link
                patch={~p"/docs/#{topic.slug}/#{section.slug}"}
                aria-current={
                  (topic.slug == @active_topic_slug and section.slug == @active_section_slug) &&
                    "page"
                }
              >
                {section.title}
              </.link>
            </li>
          </ul>
        </div>
      </nav>
    </div>
    """
  end
end
