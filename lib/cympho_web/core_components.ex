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

  attr :for, :any, required: true
  attr :as, :any, default: :global
  attr :rest, :global, include: ~w(method action)

  def simple_form(assigns) do
    ~H"""
    <form {@rest}>
      <%= render_slot(@inner_block) %>
    </form>
    """
  end

  attr :field, :any, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="form-group">
      <label><%= @label %></label>
      <input type={@type} name={input_name(@field)} value={input_value(@field)} {@rest} />
    </div>
    """
  end

  attr :type, :string, default: "submit"
  attr :rest, :global

  def button(assigns) do
    ~H"""
    <button type={@type} {@rest}>
      <%= render_slot(@inner_block) %>
    </button>
    """
  end

  defp input_name(field), do: field.name
  defp input_value(field), do: Ecto.Changeset.get_change(field.source, field.name) || field.data[field.name]
end
