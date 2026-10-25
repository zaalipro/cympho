defmodule CymphoWeb.DetailsOpenStateTest do
  @moduledoc """
  A LiveView patch rewrites the attributes of every element it re-renders, so
  the `open` a reader set on a `<details>` is dropped on the next update: a
  reply from another page closed the Task page's brief, thread and
  deliverables (smoke B1), an answer closed the Inbox's Decided list (B2).
  Every `<details>` a LiveView renders must ignore `open` on patch, and carry
  an id so the patch keeps its element.
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

  # Ignoring `open` only helps while the patch keeps the reader's element. morphdom
  # matches an element without an id by position, so a sibling inserted before it
  # (a Paused chip, a new hire), a re-keyed sibling (a Next step that switches
  # branch) or a reordered list replaces it, closed, or hands its `open` to a
  # neighbour. An id (from the item, in a list) keeps each element.
  test "every <details> a LiveView renders has an id, so a patch keeps its element" do
    unkeyed =
      for path <- Path.wildcard("lib/cympho_web/**/*.{ex,heex}"),
          path not in @root_layout_only,
          {tag, line} <- details_tags(File.read!(path)),
          not (tag =~ ~r/\sid=/),
          do: "#{path}:#{line}"

    assert unkeyed == []
  end

  # Where the server derives `open` from the data, ignoring it on patch would
  # also hide a change of that state (a run fails, a PR is set, Back restores a
  # filter). Those render it again as data-open for the ServerOpen hook
  # (assets/js/app.js); the Inbox's Decided list instead swaps its id with
  # ?decided, so the patch brings a new element.
  test "a <details> whose open comes from the server still follows that state" do
    unfollowed =
      for path <- Path.wildcard("lib/cympho_web/**/*.{ex,heex}"),
          path not in @root_layout_only,
          {tag, line} <- details_tags(File.read!(path)),
          tag =~ ~r/\sopen=/,
          not (tag =~ ~s(phx-hook="ServerOpen") and tag =~ "data-open="),
          not String.contains?(tag, "id={if @decided_open"),
          do: "#{path}:#{line}"

    assert unfollowed == []
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
