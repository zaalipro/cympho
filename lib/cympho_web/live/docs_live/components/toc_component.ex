defmodule CymphoWeb.DocsLive.Components.TocComponent do
  @moduledoc """
  Right-hand "On this page" scrollspy table of contents with mobile drawer support.
  """
  use Phoenix.Component

  attr :anchors, :list, default: []

  def toc(assigns) do
    ~H"""
    <div :if={@anchors != []} class="w-56 shrink-0 hidden xl:block">
      <div class="sticky top-20 pl-4 border-l border-hairline space-y-3">
        <p class="text-[11px] font-510 tracking-[0.06em] uppercase text-ink-tertiary">
          On this page
        </p>

        <ul class="space-y-1.5 text-[13px]">
          <%= for anchor <- @anchors do %>
            <li class={if anchor.level == 3, do: "pl-3", else: ""}>
              <a
                href={"##{anchor.id}"}
                class="block text-ink-subtle hover:text-ink transition-colors truncate"
              >
                {anchor.title}
              </a>
            </li>
          <% end %>
        </ul>

        <div class="pt-3 border-t border-hairline">
          <a
            href="#doc-top"
            class="text-xs text-brand hover:underline inline-flex items-center gap-1"
          >
            <span>Back to top</span>
            <span>↑</span>
          </a>
        </div>
      </div>
    </div>
    """
  end

  attr :anchors, :list, default: []

  def mobile_toc(assigns) do
    ~H"""
    <details
      :if={@anchors != []}
      class="xl:hidden my-4 rounded-xl border border-hairline bg-surface-2 p-3 text-sm"
      phx-mounted={Phoenix.LiveView.JS.ignore_attributes("open")}
    >
      <summary class="font-510 text-ink cursor-pointer flex items-center justify-between">
        <span>On this page ({length(@anchors)} sections)</span>
        <span class="text-xs text-ink-tertiary">Expand ▾</span>
      </summary>
      <ul class="mt-3 space-y-1.5 pl-2 border-l border-hairline text-xs">
        <%= for anchor <- @anchors do %>
          <li class={if anchor.level == 3, do: "pl-3", else: ""}>
            <a
              href={"##{anchor.id}"}
              class="block py-0.5 text-ink-subtle hover:text-ink transition-colors truncate"
            >
              {anchor.title}
            </a>
          </li>
        <% end %>
      </ul>
    </details>
    """
  end
end
