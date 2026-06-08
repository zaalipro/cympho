defmodule CymphoWeb.Components.Card do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class="rounded-xl border border-border bg-panel shadow-card card-lift hover:bg-surface-hover hover:shadow-raised"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
