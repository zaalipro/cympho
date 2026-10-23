defmodule Cympho.Themes do
  @moduledoc """
  Single source of truth for the app's appearance modes.

  Cympho has one theme, Paper & Ink, in three modes: Light, Dark and System
  (follows the device; the default for new users). The id is stored in
  `users.theme` and stamped as `<html data-mode>`; the tokens live in
  `assets/css/app.css` (`:root`, light) and `assets/css/themes.css` (dark).
  Consumed by:

    * `CymphoWeb.Plugs.FetchTheme` — read the cookie and stamp `<html>`
    * `Cympho.Users.User.theme_changeset/2` — `validate_inclusion`
    * `CymphoWeb.SettingsLive.Appearance` — render the picker
  """

  @default "system"

  @themes [
    %{id: "light", name: "Light", blurb: "Paper and ink"},
    %{id: "dark", name: "Dark", blurb: "Ink and paper"},
    %{id: "system", name: "System", blurb: "Follows this device"}
  ]

  @ids Enum.map(@themes, & &1.id)

  # Users who picked one of the twelve retired palettes keep a sensible mode:
  # the stored id is mapped at read time (never written back), dark palettes
  # to Dark and light ones to Light. Anything else follows the device.
  @legacy_modes %{
    "claude" => "dark",
    "clickhouse" => "dark",
    "spotify" => "dark",
    "bmw-m" => "dark",
    "bugatti" => "dark",
    "notion" => "light",
    "cal" => "light",
    "cursor" => "light",
    "figma" => "light",
    "minimax" => "light",
    "stripe" => "light",
    "vercel" => "light",
    "airtable" => "light"
  }

  @doc "All modes, in display order."
  def all, do: @themes

  @doc "All valid mode ids."
  def ids, do: @ids

  @doc "The default mode id."
  def default, do: @default

  @doc "Whether the given id is a mode that may be stored."
  def valid?(id) when is_binary(id), do: id in @ids
  def valid?(_), do: false

  @doc "Coerce any stored or cookie value to a mode id (legacy palettes map to their mode)."
  def normalize(id) when is_binary(id) do
    cond do
      valid?(id) -> id
      mode = Map.get(@legacy_modes, id) -> mode
      true -> @default
    end
  end

  def normalize(_), do: @default

  @doc "Fetch a single mode map by id, or nil."
  def get(id), do: Enum.find(@themes, &(&1.id == id))
end
