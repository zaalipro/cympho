defmodule CymphoWeb.Components.SettingsLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CymphoWeb.Components.SettingsLayout

  defp render_settings(active) do
    assigns = %{active: active}

    rendered_to_string(~H"""
    <SettingsLayout.settings_layout active={@active}>
      <p>CONTENT-MARKER</p>
    </SettingsLayout.settings_layout>
    """)
  end

  test "renders the three groups, the content slot, and every tab link" do
    html = render_settings(:appearance)

    for group <- ~w(Account Workspace Governance), do: assert(html =~ group)
    assert html =~ "CONTENT-MARKER"

    for {label, path} <- [
          {"Profile", "/settings/profile"},
          {"Appearance", "/settings/appearance"},
          {"Notifications", "/settings/notifications"},
          {"Integrations", "/settings/integrations"},
          {"Adapters", "/settings/adapters"},
          {"Secrets", "/settings/secrets"},
          {"Execution policies", "/settings/policies"},
          {"Audit log", "/settings/audit"}
        ] do
      assert html =~ label
      assert html =~ ~s(href="#{path}")
    end
  end

  test "marks exactly the active tab with aria-current and the active style" do
    html = render_settings(:appearance)

    # Exactly one tab is current / styled active.
    assert length(String.split(html, ~s(aria-current="page"))) - 1 == 1
    assert length(String.split(html, "bg-brand/10")) - 1 == 1

    # …and it is the Appearance tab (href precedes the rest attrs on the anchor).
    assert html =~ ~r|<a[^>]*href="/settings/appearance"[^>]*aria-current="page"|
  end

  test "active follows the passed key" do
    html = render_settings(:audit)

    assert length(String.split(html, ~s(aria-current="page"))) - 1 == 1
    assert html =~ ~r|<a[^>]*href="/settings/audit"[^>]*aria-current="page"|
    refute html =~ ~r|<a[^>]*href="/settings/appearance"[^>]*aria-current="page"|
  end
end
