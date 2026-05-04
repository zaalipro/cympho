defmodule CymphoWeb.Components.Skeleton do
  use Phoenix.Component

  attr :class, :string, default: nil
  attr :rows, :integer, default: 3
  attr :variant, :string, default: "list"
  attr :rest, :global

  def skeleton(assigns) do
    ~H"""
    <div class={["animate-pulse", @class]} {@rest}>
      <%= case @variant do %>
        <% "list" -> %>
          <div class="space-y-3">
            <%= for _ <- 1..@rows do %>
              <div class="flex items-center gap-3 p-3 bg-surface border border-border rounded-lg">
                <div class="w-8 h-8 bg-surface-hover rounded-md shrink-0"></div>
                <div class="flex-1 space-y-2">
                  <div class="h-3 bg-surface-hover rounded w-3/4"></div>
                  <div class="h-2 bg-surface-hover rounded w-1/2"></div>
                </div>
              </div>
            <% end %>
          </div>
        <% "card" -> %>
          <div class="p-4 bg-surface border border-border rounded-lg space-y-3">
            <div class="h-4 bg-surface-hover rounded w-1/3"></div>
            <div class="space-y-2">
              <div class="h-3 bg-surface-hover rounded"></div>
              <div class="h-3 bg-surface-hover rounded w-5/6"></div>
              <div class="h-3 bg-surface-hover rounded w-4/6"></div>
            </div>
          </div>
        <% "issue" -> %>
          <div class="p-4 bg-surface border border-border rounded-lg">
            <div class="flex items-start gap-3">
              <div class="w-6 h-6 bg-surface-hover rounded shrink-0 mt-0.5"></div>
              <div class="flex-1 space-y-2">
                <div class="flex items-center gap-2">
                  <div class="h-3 bg-surface-hover rounded w-16"></div>
                  <div class="h-5 bg-surface-hover rounded-full w-20"></div>
                </div>
                <div class="h-4 bg-surface-hover rounded w-3/4"></div>
                <div class="h-3 bg-surface-hover rounded w-1/2"></div>
              </div>
            </div>
          </div>
        <% "agent" -> %>
          <div class="p-4 bg-surface border border-border rounded-lg">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 bg-surface-hover rounded-full shrink-0"></div>
              <div class="flex-1 space-y-2">
                <div class="h-4 bg-surface-hover rounded w-24"></div>
                <div class="h-3 bg-surface-hover rounded w-32"></div>
              </div>
              <div class="w-2 h-2 bg-surface-hover rounded-full"></div>
            </div>
          </div>
        <% "kanban" -> %>
          <div class="space-y-3">
            <div class="h-6 bg-surface-hover rounded w-24 mb-2"></div>
            <div class="p-3 bg-surface border border-border rounded-lg">
              <div class="h-4 bg-surface-hover rounded w-full mb-2"></div>
              <div class="h-3 bg-surface-hover rounded w-2/3"></div>
            </div>
            <div class="p-3 bg-surface border border-border rounded-lg">
              <div class="h-4 bg-surface-hover rounded w-full mb-2"></div>
              <div class="h-3 bg-surface-hover rounded w-3/4"></div>
            </div>
          </div>
        <% "detail" -> %>
          <div class="space-y-4">
            <div class="flex items-center gap-3">
              <div class="h-8 bg-surface-hover rounded w-24"></div>
              <div class="h-6 bg-surface-hover rounded-full w-20"></div>
            </div>
            <div class="h-6 bg-surface-hover rounded w-1/2"></div>
            <div class="space-y-2">
              <div class="h-4 bg-surface-hover rounded"></div>
              <div class="h-4 bg-surface-hover rounded"></div>
              <div class="h-4 bg-surface-hover rounded w-5/6"></div>
            </div>
          </div>
        <% _ -> %>
          <div class="space-y-2">
            <div class="h-4 bg-surface-hover rounded w-1/3"></div>
            <div class="h-3 bg-surface-hover rounded"></div>
            <div class="h-3 bg-surface-hover rounded w-4/5"></div>
          </div>
      <% end %>
    </div>
    """
  end

  attr :class, :string, default: nil
  attr :rest, :global

  def skeleton_loading(assigns) do
    ~H"""
    <div
      class={["opacity-75", @class]}
      phx-connected={@connected_class}
      {@rest}
    >
      <div class={["opacity-0 transition-opacity duration-200", @loading_class || "phx-loading:opacity-100"]}>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end