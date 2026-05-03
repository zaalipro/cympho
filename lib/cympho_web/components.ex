defmodule CymphoWeb.Components do
  use Phoenix.Component

  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :rest, :global
  slot :inner_block
  slot :actions

  def header(assigns) do
    ~H"""
    <header class="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between" {@rest}>
      <div class="min-w-0">
        <h1 :if={@title} class="text-[22px] leading-7 font-590 tracking-tight text-text-primary">
          {@title}
        </h1>
        <p :if={@subtitle} class="mt-1 max-w-2xl text-sm leading-5 text-text-tertiary">
          {@subtitle}
        </p>
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="flex flex-wrap items-center gap-2 sm:justify-end">
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
    assigns = assign(assigns, :errors, input_errors(assigns.field))

    ~H"""
    <div class="space-y-1.5">
      <label :if={@label} class="block text-xs font-510 text-text-secondary">{@label}</label>
      <textarea
        :if={@type == "textarea"}
        name={input_name(@field, @name)}
        rows={@rows}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      ><%= input_value(@field, @value) %></textarea>
      <select
        :if={@type == "select"}
        name={input_name(@field, @name)}
        required={@required}
        disabled={@disabled}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      >
        <option
          :for={{label, value} <- select_options(@options)}
          value={value}
          selected={to_string(input_value(@field, @value)) == to_string(value)}
        >
          {label}
        </option>
      </select>
      <input
        :if={@type not in ["textarea", "select"]}
        type={@type}
        name={input_name(@field, @name)}
        value={input_value(@field, @value)}
        required={@required}
        disabled={@disabled}
        class={[
          "w-full bg-surface border rounded-lg px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors",
          input_border_class(@errors)
        ]}
        {@rest}
      />
      <p :for={error <- @errors} class="text-xs text-error">
        {error}
      </p>
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
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center gap-2 font-medium transition-colors rounded-lg",
        button_variant(@variant),
        button_size(@size)
      ]}
      {@rest}
    >
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
        class="w-full bg-surface border border-border rounded-lg px-3.5 py-2 text-sm text-text-primary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand transition-colors appearance-none"
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

  defp input_name(_field, name) when is_binary(name), do: name
  defp input_name(%{name: name}, _name), do: name
  defp input_name(_, _), do: nil

  defp input_value(_field, value) when not is_nil(value), do: value
  defp input_value(%{value: value}, _value), do: value
  defp input_value(_, _), do: nil

  defp select_options(nil), do: []

  defp select_options(options) do
    Enum.map(options, fn
      {label, value} -> {label, value}
      value -> {value, value}
    end)
  end

  defp button_variant("primary"), do: "bg-brand text-white hover:bg-accent"

  defp button_variant("secondary"),
    do: "bg-button text-text-primary border border-border hover:bg-button-hover"

  defp button_variant("ghost"), do: "text-text-secondary hover:bg-surface-hover"
  defp button_variant("danger"), do: "bg-error text-white hover:bg-red-600"

  defp button_variant(_),
    do: "bg-button text-text-primary border border-border hover:bg-button-hover"

  defp button_size("sm"), do: "px-3 py-1.5 text-xs"
  defp button_size("lg"), do: "px-6 py-3 text-base"
  defp button_size(_), do: "px-4 py-2 text-sm"

  attr :field, :any, required: true

  def error(assigns) do
    assigns = assign(assigns, :errors, input_errors(assigns.field))

    ~H"""
    <div :for={error <- @errors} class="text-xs text-error mt-1">
      {error}
    </div>
    """
  end

  defp input_errors(nil), do: []
  defp input_errors(%{errors: errors}), do: Enum.map(errors, &format_input_error/1)
  defp input_errors(_), do: []

  defp format_input_error({message, opts}) when is_binary(message) and is_list(opts) do
    Enum.reduce(opts, message, fn
      {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))

      _, acc ->
        acc
    end)
  end

  defp format_input_error(message) when is_binary(message), do: message
  defp format_input_error(message), do: inspect(message)

  defp input_border_class([]), do: "border-border"
  defp input_border_class(_), do: "border-error/60"
end
