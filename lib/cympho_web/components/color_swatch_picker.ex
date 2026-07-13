defmodule CymphoWeb.Components.ColorSwatchPicker do
  @moduledoc """
  8 preset hex swatches plus a custom hex input. The form field receives
  the hex string. No JS hook required — clicking a swatch updates the
  hidden input via a tiny inline handler.
  """
  use Phoenix.Component

  @presets [
    {"Terracotta", "#D97757"},
    {"Amber", "#e8a55a"},
    {"Sage", "#5db872"},
    {"Teal", "#5db8a6"},
    {"Plum", "#9A7CA8"},
    {"Rose", "#A96B83"},
    {"Red", "#c64545"},
    {"Slate", "#807A6F"}
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
            "flex h-7 w-7 items-center justify-center rounded-full border",
            "transition-transform duration-200 ease-[cubic-bezier(0.32,0.72,0,1)] hover:scale-110 active:scale-95",
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
            style={"background-color: #{@field.value || "#423F3B"}"}
          >
          </span>
          <input
            type="text"
            name={@field.name}
            id={@field.id}
            data-hex-input
            value={@field.value}
            placeholder="#D97757"
            maxlength="7"
            class="w-28 bg-surface border border-border rounded-xl px-2.5 py-1.5 text-xs font-mono text-text-primary transition duration-150 hover:border-hairline-strong focus:outline-none focus:ring-2 focus:ring-brand/25 focus:border-brand focus:shadow-[0_0_16px_-4px_rgb(var(--color-primary-rgb)/0.35)]"
          />
        </div>
      </div>
      <p :if={@field.errors != []} class="flex items-center gap-1 text-xs text-error">
        <span class="hero-exclamation-triangle-mini h-3.5 w-3.5 shrink-0" aria-hidden="true"></span>
        {Enum.map_join(@field.errors, ", ", fn {msg, _} -> msg end)}
      </p>
    </div>
    """
  end
end
