defmodule CymphoWeb.Components.Card do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-border bg-panel shadow-ring transition-colors hover:bg-surface-hover"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
