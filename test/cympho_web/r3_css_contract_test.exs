defmodule CymphoWeb.R3CssContractTest do
  @moduledoc """
  The Paper & Ink theming contract (port of the mockups' check.py token rules):
  light tokens on `app.css :root`, the dark block twice in `themes.css` and
  identical, and no colour literal in the r3 component or page CSS.
  """
  use ExUnit.Case, async: true

  @app_css "assets/css/app.css"
  @themes_css "assets/css/themes.css"
  @r3_css "assets/css/r3.css"
  @pages_glob "assets/css/r3-pages/*.css"

  @dark_media ~s|:root:not([data-mode="light"])|
  @dark_attr ~s|:root[data-mode="dark"]|

  # Copied verbatim from the mockups' check.py (COLOUR, line 91).
  @colour ~r/#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color-mix)\(|(?<![-\w])(?:white|black|red|green|blue|gray|grey|orange|silver)(?![-\w])/

  # Mode-independent tokens that look like colours: an alpha mask and the
  # shadow channel triple.
  @mode_independent ~w(--mask --shadow-rgb)

  defp read(path), do: path |> File.read!() |> strip_comments()
  defp strip_comments(css), do: Regex.replace(~r{/\*.*?\*/}s, css, "")

  # Body of the first rule whose selector is `selector`, found by brace matching.
  defp block(css, selector) do
    {start, len} = :binary.match(css, selector)
    rest = binary_part(css, start + len, byte_size(css) - start - len)
    {open, 1} = :binary.match(rest, "{")
    body_from = binary_part(rest, open + 1, byte_size(rest) - open - 1)
    take_balanced(body_from, 1, [])
  end

  defp take_balanced(<<"}", _::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<"}", rest::binary>>, d, acc), do: take_balanced(rest, d - 1, ["}" | acc])
  defp take_balanced(<<"{", rest::binary>>, d, acc), do: take_balanced(rest, d + 1, ["{" | acc])

  defp take_balanced(<<c::utf8, rest::binary>>, d, acc),
    do: take_balanced(rest, d, [<<c::utf8>> | acc])

  defp declarations(body) do
    ~r/(--[\w-]+)\s*:\s*([^;]+);/
    |> Regex.scan(body)
    |> Map.new(fn [_, name, value] -> {name, String.trim(value)} end)
  end

  defp light, do: @app_css |> read() |> block(":root") |> declarations()
  defp dark_1, do: @themes_css |> read() |> block(@dark_media)
  defp dark_2, do: @themes_css |> read() |> block(@dark_attr)

  defp r3_sources, do: [@r3_css | Path.wildcard(@pages_glob)]

  test "the dark block appears twice, once per selector, and both copies are identical" do
    themes = read(@themes_css)

    assert themes =~ "@media (prefers-color-scheme: dark)"
    assert themes =~ @dark_media
    assert themes =~ @dark_attr

    normalize = &String.replace(&1, ~r/\s+/, "")
    assert normalize.(dark_1()) == normalize.(dark_2())
  end

  test "every light colour token has a dark value" do
    dark_names = dark_1() |> declarations() |> Map.keys() |> MapSet.new()

    colour_tokens =
      for {name, value} <- light(),
          name not in @mode_independent,
          String.contains?(value, ["#", "rgb(", "rgba("]) or String.ends_with?(name, "-rgb"),
          do: name

    missing = Enum.reject(colour_tokens, &MapSet.member?(dark_names, &1))
    assert missing == [], "colour tokens without a dark value: #{inspect(missing)}"
  end

  test "every dark token has a light value" do
    light_names = light() |> Map.keys() |> MapSet.new()

    extra =
      dark_1() |> declarations() |> Map.keys() |> Enum.reject(&MapSet.member?(light_names, &1))

    assert extra == [], "dark tokens without a light value: #{inspect(extra)}"
  end

  test "every var() without a fallback in the r3 CSS names a declared token" do
    declared =
      [@app_css, @themes_css | r3_sources()]
      |> Enum.flat_map(fn path ->
        Regex.scan(~r/(--[\w-]+)\s*:/, read(path), capture: :all_but_first)
      end)
      |> List.flatten()
      |> MapSet.new()

    undefined =
      r3_sources()
      |> Enum.flat_map(
        &Regex.scan(~r/var\(\s*(--[\w-]+)\s*\)/, read(&1), capture: :all_but_first)
      )
      |> List.flatten()
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(declared, &1))

    assert undefined == [], "var() of an undefined token: #{inspect(undefined)}"
  end

  test "r3 component and page CSS carry no colour literal" do
    for path <- r3_sources() do
      hits = @colour |> Regex.scan(read(path)) |> List.flatten() |> Enum.uniq()
      assert hits == [], "colour literals in #{path}: #{inspect(hits)}"
    end
  end

  test "the six page CSS files exist and are imported by app.css" do
    app = File.read!(@app_css)

    for page <- ~w(home task agents work money onboarding) do
      assert File.exists?("assets/css/r3-pages/#{page}.css")
      assert app =~ ~s|@import "r3-pages/#{page}.css";|
    end

    assert app =~ ~s|@import "r3.css";|
  end
end
