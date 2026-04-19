defmodule CymphoWeb.CoreComponents do
  use Phoenix.Component

  attr :title, :string, default: nil
  attr :rest, :global
  slot :actions
  slot :inner_block

  def header(assigns) do
    ~H"""
    <header {@rest}>
      <h1><%= @title || render_slot(@inner_block) %></h1>
      <div :if={@actions != []} class="header-actions">
        <%= render_slot(@actions) %>
      </div>
    </header>
    """
  end
end
