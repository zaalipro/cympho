defmodule Cympho.ThemesTest do
  use ExUnit.Case, async: true

  alias Cympho.Themes

  @legacy_dark ~w(claude clickhouse spotify bmw-m bugatti)
  @legacy_light ~w(notion cal cursor figma minimax stripe vercel airtable)

  test "offers exactly the three Paper & Ink modes" do
    assert Themes.ids() == ~w(light dark system)
    assert Enum.map(Themes.all(), & &1.name) == ["Light", "Dark", "System"]
  end

  test "new users follow the device" do
    assert Themes.default() == "system"
  end

  test "modes normalize to themselves" do
    for id <- ~w(light dark system), do: assert(Themes.normalize(id) == id)
  end

  test "legacy dark palettes read as dark" do
    for id <- @legacy_dark, do: assert(Themes.normalize(id) == "dark")
  end

  test "legacy light palettes read as light" do
    for id <- @legacy_light, do: assert(Themes.normalize(id) == "light")
  end

  test "unknown or missing values follow the device" do
    assert Themes.normalize(nil) == "system"
    assert Themes.normalize("bogus") == "system"
    assert Themes.normalize(42) == "system"
  end

  test "legacy ids are not valid to store" do
    refute Themes.valid?("claude")
    assert Themes.valid?("dark")
  end
end
