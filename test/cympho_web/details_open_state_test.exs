defmodule CymphoWeb.DetailsOpenStateTest do
  @moduledoc """
  A LiveView patch rewrites the attributes of every element it re-renders, so
  the `open` a reader set on a `<details>` is dropped on the next update: a
  reply from another page closed the Task page's brief, thread and
  deliverables (smoke B1), an answer closed the Inbox's Decided list (B2).
  Every `<details>` a LiveView renders must ignore `open` on patch.
  """
  use ExUnit.Case, async: true

  # Rendered only by the root layout, which LiveView never patches.
  @root_layout_only ~w(
    lib/cympho_web/components/company_rail.ex
    lib/cympho_web/components/user_menu.ex
  )

  test "every <details> a LiveView renders keeps its open state across patches" do
    missing =
      for path <- Path.wildcard("lib/cympho_web/**/*.{ex,heex}"),
          path not in @root_layout_only,
          {tag, line} <- details_tags(File.read!(path)),
          not String.contains?(tag, ~s|ignore_attributes("open")|),
          do: "#{path}:#{line}"

    assert missing == []
  end

  # Each `<details` opening tag with its line; a backticked mention in a doc is not a tag.
  defp details_tags(source) do
    ~r/(?<!`)<details(?=[\s>])/
    |> Regex.scan(source, return: :index)
    |> Enum.map(fn [{start, _}] ->
      line = source |> binary_part(0, start) |> String.split("\n") |> length()
      {open_tag(binary_part(source, start, byte_size(source) - start), 0, []), line}
    end)
  end

  # The opening tag ends at the first `>` outside a `{...}` expression.
  defp open_tag(<<">", _::binary>>, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()
  defp open_tag(<<"{", rest::binary>>, depth, acc), do: open_tag(rest, depth + 1, ["{" | acc])
  defp open_tag(<<"}", rest::binary>>, depth, acc), do: open_tag(rest, depth - 1, ["}" | acc])
  defp open_tag(<<c, rest::binary>>, depth, acc), do: open_tag(rest, depth, [c | acc])
end
