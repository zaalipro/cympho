defmodule CymphoWeb.Components do
  use Phoenix.Component

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :rest, :global
  slot :inner_block
  slot :actions

  def header(assigns) do
    ~H"""
    <header {@rest}>
      <h1 :if={@title}>{@title}</h1>
      <p :if={@subtitle} class="text-text-secondary text-sm mt-1">{@subtitle}</p>
      <div class="header-actions">
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="header-actions">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :navigate, :string, required: true
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def app_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      class={["text-text-secondary hover:text-text-primary transition-colors", @class]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :for, :any, required: true
  attr :as, :any, default: :global
  attr :rest, :global, include: ~w(method action)
  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <form {@rest}>
      {render_slot(@inner_block)}
      <div :if={@actions != []} class="form-actions">
        {render_slot(@actions)}
      </div>
    </form>
    """
  end

  attr :field, :any, default: nil
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :required, :boolean, default: false
  attr :disabled, :boolean, default: false
  attr :rows, :integer, default: nil
  attr :options, :list, default: nil
  attr :step, :string, default: nil
  attr :max, :string, default: nil
  attr :min, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :phx_change, :string, default: nil
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="form-group">
      <label>{@label}</label>
      <textarea
        :if={@type == "textarea"}
        name={input_name(@field)}
        rows={@rows}
        {@rest}
      ><%= input_value(@field) %></textarea>
      <input
        :if={@type != "textarea"}
        type={@type}
        name={input_name(@field)}
        value={input_value(@field)}
        required={@required}
        {@rest}
      />
    </div>
    """
  end

  attr :type, :string, default: "submit"
  attr :variant, :string, default: nil
  attr :size, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button type={@type} {@rest}>
      {render_slot(@inner_block)}
    </button>
    """
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, default: nil
  attr :required, :boolean, default: false
  attr :rest, :global

  def select(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label class="block text-xs font-510 text-text-secondary">{@label}</label>
      <select
        name={@name}
        class="w-full bg-white/[0.05] border border-border rounded-md px-3.5 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-accent/30 focus:border-accent transition-colors appearance-none"
        {@rest}
      >
        <option
          :for={{label, value} <- Enum.map(@options, fn {k, v} -> {to_string(k), v} end)}
          value={value}
          selected={@value == value}
        >
          {label}
        </option>
      </select>
    </div>
    """
  end

  defp input_name(field), do: field.name

  defp input_value(field), do: field.value


  attr :field, :any, required: true

  def error(assigns) do
    ~H"""
    <div :for={error <- List.wrap(@field.errors)} class="text-xs text-red-400 mt-1">
      {error}
    </div>
    """
  end
end
