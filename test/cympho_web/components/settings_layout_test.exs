defmodule CymphoWeb.Components.SettingsLayoutTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias CymphoWeb.Components.SettingsLayout

  # r3 (P8): the section nav is regrouped as Company · Connections · You · Labels;
  # one nav for both modes, Advanced-only sections carry ui-advanced-only.
  defp render_settings(active) do
    assigns = %{active: active}

    rendered_to_string(~H"""
    <SettingsLayout.settings_layout active={@active}>
      <p>CONTENT-MARKER</p>
    </SettingsLayout.settings_layout>
    """)
  end

  test "renders the groups, the content slot, and every section link" do
    html = render_settings(:appearance)
    doc = Floki.parse_fragment!(html)

    assert doc |> Floki.find(".sn-g") |> Enum.map(&Floki.text/1) == [
             "Company",
             "Connections",
             "You"
           ]

    assert html =~ "CONTENT-MARKER"

    for {label, path} <- [
          {"Details", "/settings/company?section=details"},
          {"Members", "/settings/company?section=members"},
          {"Billing", "/settings/company?section=billing"},
          {"Review steps", "/settings/policies"},
          {"Audit log", "/settings/audit"},
          {"How agents run", "/settings/adapters"},
          {"Integrations", "/settings/integrations"},
          {"Keys and secrets", "/settings/secrets"},
          {"Network proxies", "/settings/proxies"},
          {"Plugins", "/plugins"},
          {"Profile", "/settings/profile"},
          {"Appearance", "/settings/appearance"},
          {"Alerts", "/settings/notifications"},
          {"Labels", "/labels"}
        ] do
      assert html =~ label
      assert html =~ ~s(href="#{path}")
    end

    advanced =
      doc |> Floki.find("li.ui-advanced-only a") |> Enum.map(&String.trim(Floki.text(&1)))

    assert advanced == ["Network proxies", "Plugins"]
  end

  test "marks exactly the active section" do
    html = render_settings(:appearance)

    assert length(String.split(html, ~s(aria-current="page"))) - 1 == 1
    assert html =~ ~r|<a[^>]*href="/settings/appearance"[^>]*aria-current="page"|
  end

  test "active follows the passed key" do
    html = render_settings(:audit)

    assert length(String.split(html, ~s(aria-current="page"))) - 1 == 1
    assert html =~ ~r|<a[^>]*href="/settings/audit"[^>]*aria-current="page"|
    refute html =~ ~r|<a[^>]*href="/settings/appearance"[^>]*aria-current="page"|
  end

  test "the section nav is labelled and sits in the settings frame" do
    doc = Floki.parse_fragment!(render_settings(:profile))

    assert doc |> Floki.find("nav.snav") |> Floki.attribute("aria-label") == ["Settings sections"]
    assert Floki.find(doc, ".lframe.set-page[data-ui-complex-page] .set .set-main") != []
  end
end
