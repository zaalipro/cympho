defmodule CymphoWeb.Components.ColorSwatchPicker do
  @moduledoc """
  8 preset hex swatches plus a custom hex input. The form field receives
  the hex string. The `ColorSwatchPicker` hook (app.js) copies a clicked
  swatch into the input and rings the swatch that matches it.

  r3 (v7 L3): a `.fld` with its label on the hex input; the swatches are the
  user's data colours, so they are the only colour written inline.
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

  defp chosen?(hex, value) when is_binary(value),
    do: String.downcase(hex) == value |> String.trim() |> String.downcase()

  defp chosen?(_hex, _value), do: false

  attr :field, Phoenix.HTML.FormField, required: true
  attr :label, :string, default: "Colour"

  def color_swatch_picker(assigns) do
    assigns =
      assigns
      |> assign(:presets, @presets)
      |> assign(:value, assigns.field.value)
      |> assign(:error_id, "#{assigns.field.id}-error")

    ~H"""
    <div class="fld swp" phx-hook="ColorSwatchPicker" id={"color-picker-#{@field.id}"}>
      <label for={@field.id}>{@label}</label>
      <div class="swp-r">
        <button
          :for={{name, hex} <- @presets}
          type="button"
          class="swp-b"
          data-swatch
          data-hex={hex}
          title={name}
          aria-label={"Set colour to #{name}"}
          aria-pressed={to_string(chosen?(hex, @value))}
          style={"background-color:#{hex}"}
        >
        </button>
        <span
          class="sw swp-pv"
          data-color-preview
          aria-hidden="true"
          style={@value not in [nil, ""] && "background-color:#{@value}"}
        >
        </span>
        <input
          type="text"
          name={@field.name}
          id={@field.id}
          data-hex-input
          value={@value}
          placeholder="#D97757"
          maxlength="7"
          aria-invalid={@field.errors != [] && "true"}
          aria-describedby={@field.errors != [] && @error_id}
        />
      </div>
      <p :if={@field.errors != []} class="err" id={@error_id} aria-live="polite">
        <CymphoWeb.Components.R3.r3_icon name="i-alert" />{Enum.map_join(@field.errors, ", ", fn {msg,
                                                                                                  _} ->
          msg
        end)}
      </p>
    </div>
    """
  end
end
