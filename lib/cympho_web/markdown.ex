defmodule CymphoWeb.Markdown do
  @moduledoc """
  Thin Earmark wrapper for rendering agent instructions and other
  user-authored markdown into HTML for display.

  Intentionally minimal — no syntax highlighting, no extensions. Returns a
  `Phoenix.HTML.safe()` value so templates can interpolate it as `{...}`.
  """

  @doc """
  Renders markdown as a safe HTML iolist. Empty/nil input returns an empty
  safe value rather than failing.
  """
  @spec to_html(binary() | nil) :: Phoenix.HTML.safe()
  def to_html(nil), do: {:safe, ""}
  def to_html(""), do: {:safe, ""}

  def to_html(text) when is_binary(text) do
    text
    |> Earmark.as_html!(escape: true, smartypants: false, compact_output: true)
    |> Phoenix.HTML.raw()
  end
end
