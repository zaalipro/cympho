defmodule CymphoWeb.Components.Card do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class="bg-panel border border-border rounded-xl shadow-ring hover:bg-surface-hover transition-colors"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
