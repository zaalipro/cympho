defmodule CymphoWeb.CoreComponents do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :title, :string, default: nil
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div id={@id} class={"fixed inset-0 z-50 flex items-center justify-center #{if @show, do: "", else: "hidden"}"}>
      <div class="fixed inset-0 bg-black/50" phx-click={@on_cancel} />
      <div class="relative bg-zinc-900 rounded-lg p-6 max-w-lg w-full mx-4 z-10">
        <h2 :if={@title} class="text-lg font-semibold mb-4">{@title}</h2>
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Renders a label for form fields.
  """
  attr :field, :any, required: true
  attr :rest, :global

  def label(assigns) do
    ~H"""
    <label for={@field} class="block text-sm font-medium text-text-secondary mb-1">{render_slot(@inner_block)}</label>
    """
  end

  @doc """
  Renders error message for form fields.
  """
  attr :field, :any, required: true
  attr :rest, :global

  def error(assigns) do
    ~H"""
    <.input :field={@field} type="hidden" value={Phoenix.HTML.FormData.form_value(@form.source, @field)} class="hidden" />
    <.input :field={@field} type="hidden" value={Phoenix.HTML.FormData.form_value(@form.source, @field) class="hidden" />
    """
  end

  @doc """
  Renders a modal dialog with backdrop.
  """
  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, :any, default: nil
  attr :title, :string, default: nil
  attr :rest, :global

  def modal(assigns) do
    ~H"""
    <div
      id={@id}
      class={"fixed inset-0 z-[60] flex items-center justify-center bg-black/50 #{if @show, do: "", else: "hidden"}"}
      phx-click={@on_cancel || JS.push("close")}
      phx-target={@myself}
    >
      <div class="fixed left-1/2 top-1/2 -translate-x-1/2 -translate-y-1/2 w-full max-w-md bg-[#0d0d0d] border border-border rounded-lg shadow-xl z-50"
           phx-click={JS.stop_propagation()}
           role="dialog"
           aria-modal="true"
           aria-labelledby={"#{@id}-title"}
      >
        <div class="p-4">
          <div class="flex items-center justify-between mb-4">
            <h2 id={"#{@id}-title"} class="text-lg font-semibold text-text-primary">
              {@title}
            </h2>
            <button
              type="button"
              phx-click={@on_cancel || JS.push("close")}
              phx-target={@myself}
              class="text-text-quaternary hover:text-text-secondary transition-colors p-1"
              aria-label="Close"
            >
              <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
              </svg>
            </button>
          </div>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end
end
