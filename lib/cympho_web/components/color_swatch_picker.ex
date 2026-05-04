defmodule CymphoWeb.Components.ColorSwatchPicker do
  @moduledoc """
  8 preset hex swatches plus a custom hex input. The form field receives
  the hex string. No JS hook required — clicking a swatch updates the
  hidden input via a tiny inline handler.
  """
  use Phoenix.Component

  @presets [
    {"Indigo", "#5e6ad2"},
    {"Pink", "#ec4899"},
    {"Blue", "#3b82f6"},
    {"Emerald", "#10b981"},
    {"Amber", "#f59e0b"},
    {"Red", "#ef4444"},
    {"Cyan", "#06b6d4"},
    {"Fuchsia", "#a855f7"}
  ]

  def presets, do: @presets

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: "Color"

  def color_swatch_picker(assigns) do
    assigns = assign(assigns, :presets, @presets)

    ~H"""
    <div class="space-y-2" phx-hook="ColorSwatchPicker" id={"color-picker-#{@field.id}"}>
      <label class="block text-xs font-510 text-text-secondary">{@label}</label>
      <div class="flex flex-wrap items-center gap-2">
        <button
          :for={{name, hex} <- @presets}
          type="button"
          data-swatch
          data-hex={hex}
          title={name}
          aria-label={"Set color to #{name}"}
          class={[
            "h-7 w-7 rounded-full border transition-transform hover:scale-110",
            "focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 focus-visible:ring-offset-canvas focus-visible:ring-brand"
          ]}
          style={"background-color: #{hex}; border-color: #{if @field.value == hex, do: "white", else: "rgba(255,255,255,0.15)"}"}
        >
          <span
            :if={to_string(@field.value || "") |> String.downcase() == hex}
            class="hero-check-mini text-white w-3.5 h-3.5"
          >
          </span>
        </button>

        <div class="ml-2 flex items-center gap-2">
          <span
            data-color-preview
            class="h-5 w-5 rounded-full border border-white/15 shrink-0"
            style={"background-color: #{@field.value || "#3b3d44"}"}
          >
          </span>
          <input
            type="text"
            name={@field.name}
            id={@field.id}
            data-hex-input
            value={@field.value}
            placeholder="#5e6ad2"
            maxlength="7"
            class="w-28 bg-surface border border-border rounded-lg px-2.5 py-1.5 text-xs font-mono text-text-primary focus:outline-none focus:ring-2 focus:ring-brand/30 focus:border-brand"
          />
        </div>
      </div>
      <p :if={@field.errors != []} class="text-xs text-red-400">
        {Enum.map_join(@field.errors, ", ", fn {msg, _} -> msg end)}
      </p>
    </div>
    """
  end
end
