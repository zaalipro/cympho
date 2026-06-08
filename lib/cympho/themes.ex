defmodule Cympho.Themes do
  @moduledoc """
  Single source of truth for the app's selectable UI themes.

  Each theme maps to a `[data-theme="<id>"]` block in `assets/css/themes.css`
  (except the default `claude`/Ember, which is the `:root` default). Consumed by:

    * `CymphoWeb.Plugs.FetchTheme` — validate the cookie and stamp `<html>`
    * `Cympho.Users.User.theme_changeset/2` — `validate_inclusion`
    * `CymphoWeb.SettingsLive.Appearance` + the user menu — render the picker

  Display names are descriptive (we adopt each design *language*, not its marks
  or proprietary fonts); the inspiration is noted only in the comment below.
  Swatch colors are approximate brand triples used purely for picker previews —
  the authoritative palettes live in the CSS.
  """

  @default "claude"
  @groups ["Dark", "Light"]

  # id          | name      | inspiration  | mode
  @themes [
    %{
      id: "claude",
      name: "Ember",
      mode: :dark,
      group: "Dark",
      blurb: "Warm terracotta charcoal — the Cympho default.",
      swatch: %{bg: "#20201E", surface: "#262624", accent: "#D97757", ink: "#FAF9F5"}
    },
    %{
      id: "clickhouse",
      name: "Voltage",
      mode: :dark,
      group: "Dark",
      blurb: "Near-black with electric-yellow voltage.",
      swatch: %{bg: "#0a0a0a", surface: "#1a1a1a", accent: "#faff69", ink: "#ffffff"}
    },
    %{
      id: "spotify",
      name: "Nocturne",
      mode: :dark,
      group: "Dark",
      blurb: "Immersive dark stage, signal green.",
      swatch: %{bg: "#121212", surface: "#181818", accent: "#1ed760", ink: "#ffffff"}
    },
    %{
      id: "bmw-m",
      name: "Circuit",
      mode: :dark,
      group: "Dark",
      blurb: "Motorsport black with the M tricolor.",
      swatch: %{bg: "#000000", surface: "#0a0a0a", accent: "#1c69d4", ink: "#ffffff"}
    },
    %{
      id: "bugatti",
      name: "Monolith",
      mode: :dark,
      group: "Dark",
      blurb: "Austere monochrome luxury.",
      swatch: %{bg: "#000000", surface: "#0d0d0d", accent: "#c3d9f3", ink: "#ffffff"}
    },
    %{
      id: "notion",
      name: "Paper",
      mode: :light,
      group: "Light",
      blurb: "Warm paper calm, a single confident blue.",
      swatch: %{bg: "#f6f5f4", surface: "#ffffff", accent: "#0075de", ink: "#101010"}
    },
    %{
      id: "cal",
      name: "Crisp",
      mode: :light,
      group: "Light",
      blurb: "Friendly white SaaS, black CTAs.",
      swatch: %{bg: "#ffffff", surface: "#f5f5f5", accent: "#111111", ink: "#111111"}
    },
    %{
      id: "cursor",
      name: "Cream",
      mode: :light,
      group: "Light",
      blurb: "Editorial warm cream, signal orange.",
      swatch: %{bg: "#f7f7f4", surface: "#ffffff", accent: "#f54e00", ink: "#26251e"}
    },
    %{
      id: "figma",
      name: "Blocks",
      mode: :light,
      group: "Light",
      blurb: "Monochrome frame, pastel color blocks.",
      swatch: %{bg: "#ffffff", surface: "#f7f7f5", accent: "#ff3d8b", ink: "#000000"}
    },
    %{
      id: "minimax",
      name: "Prism",
      mode: :light,
      group: "Light",
      blurb: "Stark white, vibrant product spectrum.",
      swatch: %{bg: "#ffffff", surface: "#ffffff", accent: "#ff5530", ink: "#0a0a0a"}
    },
    %{
      id: "stripe",
      name: "Aurora",
      mode: :light,
      group: "Light",
      blurb: "Navy ink, indigo CTA, gradient aurora.",
      swatch: %{bg: "#ffffff", surface: "#f6f9fc", accent: "#533afd", ink: "#0d253d"}
    },
    %{
      id: "vercel",
      name: "Edge",
      mode: :light,
      group: "Light",
      blurb: "Stark black-on-white, mesh gradient.",
      swatch: %{bg: "#fafafa", surface: "#ffffff", accent: "#171717", ink: "#171717"}
    },
    %{
      id: "airtable",
      name: "Workbook",
      mode: :light,
      group: "Light",
      blurb: "Sober editorial, coral & forest bands.",
      swatch: %{bg: "#ffffff", surface: "#f8f9fa", accent: "#aa2d00", ink: "#181d26"}
    }
  ]

  @ids Enum.map(@themes, & &1.id)

  @doc "All themes, in display order."
  def all, do: @themes

  @doc "All valid theme ids."
  def ids, do: @ids

  @doc "The default theme id (no `data-theme` attr == this)."
  def default, do: @default

  @doc "Whether the given id is a known theme."
  def valid?(id) when is_binary(id), do: id in @ids
  def valid?(_), do: false

  @doc "Coerce any value to a valid theme id, falling back to the default."
  def normalize(id) when is_binary(id), do: if(valid?(id), do: id, else: @default)
  def normalize(_), do: @default

  @doc "Fetch a single theme map by id, or nil."
  def get(id), do: Enum.find(@themes, &(&1.id == id))

  @doc "The light/dark mode for an id (defaults to :dark for unknown ids)."
  def mode(id) do
    case get(id) do
      %{mode: mode} -> mode
      _ -> :dark
    end
  end

  @doc "Themes bucketed by group, in `Dark, Light` order, for the picker."
  def grouped do
    Enum.map(@groups, fn group ->
      {group, Enum.filter(@themes, &(&1.group == group))}
    end)
  end
end
