defmodule CymphoWeb.DocsLive.Components.CalloutComponent do
  @moduledoc """
  Editorial callout cards (info, note, warning, tip, code) conforming
  to Cympho's dark-mode Ember palette.
  """
  use Phoenix.Component

  attr :type, :atom, default: :info, values: [:info, :note, :warning, :tip, :code]
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def callout(assigns) do
    ~H"""
    <div class={callout_classes(@type)}>
      <div class="flex items-start gap-3">
        <.callout_icon type={@type} />
        <div class="flex-1 space-y-1">
          <p :if={@title} class="font-serif text-[14px] font-510 text-ink">
            {@title}
          </p>
          <div class="text-[13px] leading-relaxed text-ink-muted">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp callout_classes(:warning) do
    "my-5 rounded-xl border border-warning/30 bg-warning/10 p-4 text-ink-muted"
  end

  defp callout_classes(:tip) do
    "my-5 rounded-xl border border-success/30 bg-success/10 p-4 text-ink-muted"
  end

  defp callout_classes(:code) do
    "my-5 rounded-xl border border-hairline bg-surface-2 p-4 text-ink-muted font-mono"
  end

  defp callout_classes(_info) do
    "my-5 rounded-xl border border-brand/30 bg-brand/10 p-4 text-ink-muted"
  end

  defp callout_icon(%{type: :warning} = assigns) do
    ~H"""
    <svg
      class="w-5 h-5 text-warning shrink-0 mt-0.5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
      />
    </svg>
    """
  end

  defp callout_icon(%{type: :tip} = assigns) do
    ~H"""
    <svg
      class="w-5 h-5 text-success shrink-0 mt-0.5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z"
      />
    </svg>
    """
  end

  defp callout_icon(%{type: :code} = assigns) do
    ~H"""
    <svg
      class="w-5 h-5 text-ink-subtle shrink-0 mt-0.5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M10 20l4-16m4 4l4 4-4 4M6 16l-4-4 4-4"
      />
    </svg>
    """
  end

  defp callout_icon(assigns) do
    ~H"""
    <svg
      class="w-5 h-5 text-brand shrink-0 mt-0.5"
      fill="none"
      stroke="currentColor"
      viewBox="0 0 24 24"
    >
      <path
        stroke-linecap="round"
        stroke-linejoin="round"
        stroke-width="2"
        d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
      />
    </svg>
    """
  end
end
