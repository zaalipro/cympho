defmodule CymphoWeb.Components do
  use Phoenix.Component

  # Header
  attr :title, :string, required: true
  attr :rest, :global
  slot :actions
  slot :inner_block

  def header(assigns) do
    ~H"""
    <header {@rest} class="flex items-center justify-between mb-8">
      <h1 class="text-2xl font-510 tracking-tight text-text-primary">
        {@title || render_slot(@inner_block)}
      </h1>
      <div :if={@actions != []} class="flex items-center gap-3">
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  # App Link
  attr :navigate, :string, required: true
  attr :class, :string, default: ""
  attr :rest, :global
  slot :inner_block, required: true

  def app_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class={["text-text-secondary hover:text-text-primary transition-colors", @class]} {@rest}>
      {render_slot(@inner_block)}
    </.link>
    """
  end

  # Simple Form
  attr :for, :any, required: true
  attr :as, :any, default: :global
  attr :rest, :global, include: ~w(method action)
  slot :inner_block, required: true
  slot :actions

  def simple_form(assigns) do
    ~H"""
    <form {@rest} class="bg-surface border border-border rounded-card p-6">
      <div class="space-y-5">
        {render_slot(@inner_block)}
      </div>
      <div :if={@actions != []} class="mt-6 flex items-center justify-end gap-3">
        {render_slot(@actions)}
      </div>
    </form>
    """
  end

  # Input
  attr :field, :any, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :rest, :global

  def input(assigns) do
    ~H"""
    <div class="space-y-1.5">
      <label class="block text-xs font-510 text-text-secondary">{@label}</label>
      <input
        :if={@type != "textarea"}
        type={@type}
        name={input_name(@field)}
        value={input_value(@field)}
        class="w-full bg-white/[0.05] border border-border rounded-md px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-accent/30 focus:border-accent transition-colors"
        {@rest}
      />
      <textarea
        :if={@type == "textarea"}
        name={input_name(@field)}
        class="w-full bg-white/[0.05] border border-border rounded-md px-3.5 py-2 text-sm text-text-primary placeholder:text-text-quaternary focus:outline-none focus:ring-2 focus:ring-accent/30 focus:border-accent transition-colors min-h-[100px] resize-y"
        {@rest}
      >{input_value(@field)}</textarea>
    </div>
    """
  end

  # Button
  attr :type, :string, default: "submit"
  attr :variant, :string, default: "primary"
  attr :rest, :global
  slot :inner_block, required: true

  def button(assigns) do
    ~H"""
    <button
      type={@type}
      class={[
        "inline-flex items-center justify-center font-510 text-sm px-4 py-2 rounded-md transition-colors cursor-pointer",
        @variant == "primary" && "bg-brand hover:bg-accent text-white",
        @variant == "ghost" && "bg-white/[0.05] hover:bg-white/[0.08] border border-border text-text-secondary hover:text-text-primary",
        @variant == "danger" && "bg-red-500/10 hover:bg-red-500/20 text-red-400 border border-red-500/20"
      ]}
      {@rest}
    >
      {render_slot(@inner_block)}
    </button>
    """
  end

  # Select
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, default: nil
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
        <option :for={{label, value} <- Enum.map(@options, fn {k, v} -> {to_string(k), v} end)} value={value} selected={@value == value}>
          {label}
        </option>
      </select>
    </div>
    """
  end

  defp input_name(field), do: field.name

  defp input_value(field), do: field.value
end
