defmodule CymphoWeb.SettingsHubTest do
  @moduledoc """
  End-to-end checks that the consolidated Settings hub mounts every relocated
  tab inside the shared shell, and that pre-hub URLs still redirect in.
  """
  use CymphoWeb.LiveCase, async: true

  describe "hub tabs mount inside the shared shell" do
    test "profile", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/profile")
      assert html =~ "Profile"
      assert html =~ "Save changes"
      # grouped sub-nav from the shell
      assert html =~ "Account"
      assert html =~ "Workspace"
      assert html =~ "Governance"
    end

    test "adapters", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters")
      assert html =~ "Adapter Status Overview"
    end

    test "secrets (company derived from current_company, no path param)", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/secrets")
      assert html =~ "Add Secret"
    end

    test "execution policies", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/policies")
      assert html =~ "No execution policies yet."
    end

    test "audit log", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/audit")
      assert html =~ "Audit Trail"
    end
  end

  describe "legacy URLs redirect into the hub" do
    test "bare /settings", %{conn: conn} do
      assert redirected_to(get(conn, "/settings")) == "/settings/profile"
    end

    test "/adapters", %{conn: conn} do
      assert redirected_to(get(conn, "/adapters")) == "/settings/adapters"
    end

    test "/audit-trail", %{conn: conn} do
      assert redirected_to(get(conn, "/audit-trail")) == "/settings/audit"
    end

    test "/execution-policies", %{conn: conn} do
      assert redirected_to(get(conn, "/execution-policies")) == "/settings/policies"
    end

    test "/companies/:id/secrets switches to that company before the hub", %{
      conn: conn,
      current_company: company
    } do
      # Honors the company in the path (membership-checked by the switcher) so an
      # old deep link doesn't silently show a different company's secrets.
      assert redirected_to(get(conn, "/companies/#{company.id}/secrets")) ==
               "/switch-company/#{company.id}?return_to=%2Fsettings%2Fsecrets"
    end
  end
end
