defmodule CymphoWeb.AuthHTML do
  @moduledoc """
  The signed-out pages (sign in, first-run setup, setup locked) in Paper & Ink.

  They use their own root layout (`root.html.heex` here), not the app's:
  the app's root layout always renders the signed-in chrome (quick create,
  command palette, company switcher) that app.js opens from global keys.
  The mode resolves exactly as in the app shell, from `<html data-mode>`
  (the theme cookie, via `CymphoWeb.Plugs.FetchTheme`) and the tokens in
  app.css, with the page rules in `assets/css/r3-pages/auth.css`. The
  pages carry no script, so nothing here needs the CSP nonce.
  """

  use CymphoWeb, :html

  embed_templates "auth_html/*"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :type, :string, default: "text"
  attr :value, :string, default: nil
  attr :error, :string, default: nil
  attr :rest, :global, include: ~w(autocomplete minlength required)

  @doc "A labelled field with onboarding's error line under it."
  def auth_field(assigns) do
    ~H"""
    <div class="fld">
      <label for={@id}>{@label}</label>
      <input
        id={@id}
        name={@name}
        type={@type}
        value={@value}
        aria-invalid={@error && "true"}
        aria-describedby={@error && @id <> "-e"}
        {@rest}
      />
      <p :if={@error} class="err" id={@id <> "-e"}><.r3_icon name="i-alert" />{@error}</p>
    </div>
    """
  end
end
