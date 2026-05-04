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
    <div
      id={@id}
      class={"fixed inset-0 z-50 flex items-center justify-center #{if @show, do: "", else: "hidden"}"}
    >
      <div class="fixed inset-0 bg-black/30" phx-click={@on_cancel} />
      <div class="relative bg-panel border border-border rounded-lg shadow-dialog p-6 max-w-lg w-full mx-4 z-10">
        <h2 :if={@title} class="font-serif text-lg font-medium text-text-primary mb-4">{@title}</h2>
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

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles -- outline (default), solid, and mini.
  Pass `name="hero-pencil"` for outline, `"hero-pencil-solid"` for solid,
  `"hero-pencil-mini"` for mini.

  ## Examples

      <.icon name="hero-x-mark" class="w-5 h-5" />
      <.icon name="hero-pencil-solid" class="w-4 h-4 text-primary" />
  """
  attr :name, :string, required: true
  attr :class, :string, default: nil
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end
end
