defmodule CymphoWeb.DocsLive.Components.TocComponent do
  @moduledoc """
  "On this page": a sticky rail from 1280 px, and a disclosure under the article
  title below that (company.css shows one or the other).
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  attr :anchors, :list, default: []

  def toc(assigns) do
    ~H"""
    <nav :if={@anchors != []} class="dc-toc" aria-label="On this page">
      <p class="dc-g">On this page</p>
      <ul>
        <li :for={anchor <- @anchors}>
          <a href={"##{anchor.id}"} class={anchor.level == 3 && "l3"}>{anchor.title}</a>
        </li>
      </ul>
      <a href="#doc-top" class="lnk">Back to top</a>
    </nav>
    """
  end

  attr :anchors, :list, default: []

  def mobile_toc(assigns) do
    ~H"""
    <details
      :if={@anchors != []}
      id="docs-mobile-toc"
      class="tech dc-mtoc"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary>
        <span>On this page <span class="mono">{length(@anchors)}</span></span>
        <.r3_icon name="i-chev-down" />
      </summary>
      <ul>
        <li :for={anchor <- @anchors}>
          <a href={"##{anchor.id}"} class={anchor.level == 3 && "l3"}>{anchor.title}</a>
        </li>
      </ul>
    </details>
    """
  end
end
