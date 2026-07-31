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
      <div
        class="fixed inset-0 bg-overlay backdrop-blur-md animate-fade-in"
        phx-click={@on_cancel}
      />
      <div class="dialog-enter relative bg-panel border border-border rounded-2xl shadow-dialog p-6 max-w-lg w-full mx-4 z-10">
        <button
          :if={@title}
          type="button"
          phx-click={@on_cancel}
          aria-label="Close"
          title="Close"
          class="absolute right-4 top-4 flex h-8 w-8 items-center justify-center rounded-full text-text-quaternary transition-colors duration-150 hover:bg-surface-hover hover:text-text-primary"
        >
          <.icon name="hero-x-mark-mini" class="h-4 w-4" />
        </button>
        <h2 :if={@title} class="text-card-title text-text-primary mb-4 pr-10">{@title}</h2>
        {render_slot(@inner_block)}
        <div :if={@footer != []} class="mt-5 border-t border-border pt-4">
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

  @doc """
  Renders an agent role.

  Advanced shows the role as an uppercase eyebrow ("ENGINEER"). Simple shows the
  role's icon instead — on a page that already groups agents by role, and where
  the agent's title usually says the same thing, the word is a third repeat.
  """
  attr :role, :any, required: true
  attr :class, :string, default: nil

  def role_mark(assigns) do
    ~H"""
    <span class={["inline-flex items-center", @class]}>
      <span class="ui-advanced-only ember-eyebrow">{role_word(@role)}</span>
      <span class="ui-simple-only" title={role_word(@role)} aria-label={role_word(@role)}>
        <span class={[role_glyph(@role), "block h-4 w-4", role_glyph_color(@role)]}></span>
      </span>
    </span>
    """
  end

  defp role_word(role) when is_atom(role) and not is_nil(role),
    do: role |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp role_word(role) when is_binary(role),
    do: role |> String.replace("_", " ") |> String.capitalize()

  defp role_word(_), do: "Agent"

  defp role_glyph(r) when r in [:ceo, "ceo"], do: "hero-sparkles-mini"
  defp role_glyph(r) when r in [:cto, "cto"], do: "hero-cpu-chip-mini"
  defp role_glyph(r) when r in [:engineer, "engineer"], do: "hero-wrench-screwdriver-mini"

  defp role_glyph(r) when r in [:product_manager, "product_manager"],
    do: "hero-clipboard-document-check-mini"

  defp role_glyph(r) when r in [:designer, "designer"], do: "hero-paint-brush-mini"
  defp role_glyph(_), do: "hero-user-mini"

  defp role_glyph_color(r) when r in [:ceo, "ceo"], do: "text-brand"
  defp role_glyph_color(r) when r in [:cto, "cto"], do: "text-sky-300"
  defp role_glyph_color(r) when r in [:engineer, "engineer"], do: "text-emerald-300"
  defp role_glyph_color(r) when r in [:product_manager, "product_manager"], do: "text-amber-300"
  defp role_glyph_color(r) when r in [:designer, "designer"], do: "text-fuchsia-300"
  defp role_glyph_color(_), do: "text-text-quaternary"

  @doc """
  Renders an issue priority.

  Advanced mode shows the word in a tinted pill ("High"). Simple mode shows the
  same information as a single arrow — up for urgent, down for low — because a
  row of "High / High / High" pills reads as decoration, while an arrow reads as
  direction at a glance.

  Both variants render; CSS picks one (see the `.ui-simple-only` /
  `.ui-advanced-only` convention). The arrow keeps the word as its accessible
  name so screen readers and hover still get "High priority".

      <.priority_mark priority={issue.priority} pill_class={priority_badge_class(issue.priority)} />
  """
  attr :priority, :any, required: true
  attr :pill_class, :string, default: nil
  attr :class, :string, default: nil

  def priority_mark(assigns) do
    assigns = assign(assigns, :label, priority_word(assigns.priority))

    ~H"""
    <span class={["inline-flex items-center", @class]}>
      <span class={["ui-advanced-only rounded-full px-2 py-0.5 text-[11px] font-510", @pill_class]}>
        {@label}
      </span>
      <span
        class="ui-simple-only inline-flex items-center"
        title={"#{@label} priority"}
        aria-label={"#{@label} priority"}
      >
        <span class={[priority_arrow_icon(@priority), "h-4 w-4", priority_arrow_tone(@priority)]}>
        </span>
      </span>
    </span>
    """
  end

  defp priority_word(priority) when is_atom(priority) and not is_nil(priority),
    do: priority |> Atom.to_string() |> String.capitalize()

  defp priority_word(priority) when is_binary(priority), do: String.capitalize(priority)
  defp priority_word(_), do: "None"

  defp priority_arrow_icon(p) when p in [:critical, "critical"],
    do: "hero-chevron-double-up-mini"

  defp priority_arrow_icon(p) when p in [:high, "high"], do: "hero-chevron-up-mini"
  defp priority_arrow_icon(p) when p in [:low, "low"], do: "hero-chevron-down-mini"
  defp priority_arrow_icon(_), do: "hero-minus-mini"

  defp priority_arrow_tone(p) when p in [:critical, "critical"], do: "text-red-400"
  defp priority_arrow_tone(p) when p in [:high, "high"], do: "text-amber-400"
  defp priority_arrow_tone(p) when p in [:low, "low"], do: "text-sky-300"
  defp priority_arrow_tone(_), do: "text-text-quaternary"
end
