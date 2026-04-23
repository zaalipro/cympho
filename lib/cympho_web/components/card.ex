defmodule CymphoWeb.Components.Card do
  use Phoenix.Component

  attr :rest, :global
  slot :inner_block, required: true

  def card(assigns) do
    ~H"""
    <div
      class="bg-white/[0.02] border border-border rounded-card hover:bg-white/[0.04] transition-colors"
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end
end
