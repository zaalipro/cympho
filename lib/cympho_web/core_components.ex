defmodule CymphoWeb.CoreComponents do
  use Phoenix.Component
  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :show, :boolean, default: false
  attr :on_cancel, JS, default: %JS{}
  attr :title, :string, default: nil
  slot :inner_block, required: true
  slot :footer

  def modal(assigns) do
    ~H"""
    <div id={@id} class={"fixed inset-0 z-50 flex items-center justify-center #{if @show, do: "", else: "hidden"}"}>
      <div class="fixed inset-0 bg-black/50" phx-click={@on_cancel} />
      <div class="relative bg-zinc-900 rounded-lg p-6 max-w-lg w-full mx-4 z-10">
        <h2 :if={@title} class="text-lg font-semibold mb-4">{@title}</h2>
        {render_slot(@inner_block)}
        <div :if={@footer != []} class="mt-4">
          {render_slot(@footer)}
        </div>
      </div>
    </div>
    """
  end

  def translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  def icon(assigns) do
    ~H"""
    <span class={[@class]} {@rest} />
    """
  end
end
