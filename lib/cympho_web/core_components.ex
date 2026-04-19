defmodule CymphoWeb.CoreComponents do
  use Phoenix.Component

  attr :title, :string, required: true
  attr :rest, :global

  def header(assigns) do
    ~H"""
    <header {@rest}>
      <h1><%= @title %></h1>
      <div class="header-actions">
        <%= render_slot(@inner_block) %>
      </div>
    </header>
    """
  end
end
