defmodule CymphoWeb.Markdown do
  @moduledoc """
  Thin MDEx wrapper for rendering agent instructions and other
  user-authored markdown into HTML for display.

  Intentionally minimal — no syntax highlighting; GFM-style tables,
  strikethrough and autolinks only. The rendered HTML is always
  passed through MDEx's sanitiser (an allow-list of tags, attributes and URL
  schemes), so raw HTML blocks, event-handler attributes and `javascript:`
  links in the source are stripped. `class` and `style` are stripped too:
  MDEx only allows them for syntax highlighting, which is off here, and they
  would let injected markup restyle the page (e.g. a full-screen overlay).
  Returns a `Phoenix.HTML.safe()` value so templates can interpolate it as
  `{...}`.
  """

  @presentational_attributes ~w(class style)

  @options [
    extension: [table: true, strikethrough: true, autolink: true],
    render: [unsafe: true],
    syntax_highlight: nil,
    sanitize:
      Keyword.put(
        MDEx.Document.default_sanitize_options(),
        :rm_tag_attributes,
        Map.new(~w(code div pre span), &{&1, @presentational_attributes})
      )
  ]

  @doc """
  Renders markdown as a safe HTML iolist. Empty/nil input returns an empty
  safe value rather than failing.
  """
  @spec to_html(binary() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    text
    |> MDEx.to_html!(@options)
    |> Phoenix.HTML.raw()
  end
end
