defmodule CymphoWeb.DocsLive.Components.CalloutComponent do
  @moduledoc """
  Docs callouts (info, note, warning, tip, code): a paper card with a kind tile.
  """
  use Phoenix.Component

  import CymphoWeb.Components.R3, only: [r3_icon: 1]

  attr :type, :atom, default: :info, values: [:info, :note, :warning, :tip, :code]
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def callout(assigns) do
    ~H"""
    <div class="card dc-call">
      <span class={["kt", @type == :warning && "q"]}><.r3_icon name={callout_icon(@type)} /></span>
      <div class="dc-call-b">
        <p :if={@title} class="dc-call-t">{@title}</p>
        <div class={@type == :code && "mono"}>{render_slot(@inner_block)}</div>
      </div>
    </div>
    """
  end

  defp callout_icon(:warning), do: "i-alert"
  defp callout_icon(:tip), do: "i-check"
  defp callout_icon(:code), do: "i-term"
  defp callout_icon(_info), do: "i-question"
end
