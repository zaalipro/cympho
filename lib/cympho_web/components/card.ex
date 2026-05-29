defmodule CymphoWeb.Components.Card do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class="rounded-lg border border-border bg-panel shadow-card transition-all hover:bg-surface-hover hover:shadow-raised"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
