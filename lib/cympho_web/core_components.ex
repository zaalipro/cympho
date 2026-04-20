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

  attr :for, :any, required: true
  attr :as, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <.form :let={f} for={@for} as={@as} {@rest}>
      <%= render_slot(@inner_block) %>
      <div :if={@actions != []} class="form-actions">
        <%= for action <- @actions do %>
          <%= render_slot(action) %>
        <% end %>
      </div>
    </.form>
    """
  end

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any
  attr :type, :string, default: "text"
  attr :field, Phoenix.HTML.FormField, default: nil
  attr :errors, :list, default: []
  attr :rest, :global

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = field.errors || []
    assigns = assign(assigns, field: nil, id: assigns.id || field.id, name: field.name, value: field.value, errors: errors)

    ~H"""
    <div phx-feedback-for={@name}>
      <label :if={@label} for={@id}>{@label}</label>
      <input
        :if={@type != "textarea"}
        type={@type}
        name={@name}
        id={@id}
        value={Phoenix.HTML.Form.normalize_value(@type, @value)}
        {@rest}
      />
      <textarea
        :if={@type == "textarea"}
        name={@name}
        id={@id}
        {@rest}
      ><%= Phoenix.HTML.Form.normalize_value(@type, @value) %></textarea>
      <p :for={error <- @errors} class="error">
        {CymphoWeb.CoreComponents.translate_error(error)}
      </p>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div phx-feedback-for={@name}>
      <label :if={@label} for={@id}>{@label}</label>
      <input
        :if={@type != "textarea"}
        type={@type}
        name={@name}
        id={@id}
        value={@value}
        {@rest}
      />
      <textarea
        :if={@type == "textarea"}
        name={@name}
        id={@id}
        {@rest}
      ><%= @value %></textarea>
    </div>
    """
  end

  attr :type, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type={@type} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end
end
