defmodule CymphoWeb.PluginMarketplaceLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Repo
  alias Cympho.Skills
  alias Cympho.Skills.Plugin

  describe "mount" do
    test "renders the available plugins catalog", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins/marketplace")

      assert html =~ "Plugin Marketplace"
      assert html =~ "GitHub Integration"
      assert html =~ "Slack Notifications"
      assert html =~ "Jira Sync"
    end
  end

  describe "install event" do
    test "creates a Skills.Plugin row scoped to the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      _html = render_click(view, "install", %{"identifier" => "github-integration"})

      assert {:ok, %Plugin{} = plugin} =
               Skills.get_plugin_by_identifier("github-integration", company.id)

      assert plugin.name == "GitHub Integration"
      assert plugin.status == "installed"
      assert plugin.enabled == true
    end

    test "is a no-op when the identifier is not in the available catalog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      _html = render_click(view, "install", %{"identifier" => "does-not-exist"})

      assert Repo.all(Plugin) == []
    end
  end

  describe "uninstall event" do
    test "deletes the plugin row scoped to the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _plugin} =
        Skills.create_plugin(%{
          identifier: "to-uninstall",
          name: "To Uninstall",
          version: "1.0.0",
          manifest: %{},
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      {:ok, fetched} = Skills.get_plugin_by_identifier("to-uninstall", company.id)
      _html = render_click(view, "uninstall", %{"id" => fetched.id})

      assert {:error, :not_found} = Skills.get_plugin_by_identifier("to-uninstall", company.id)
    end

    test "is a no-op when the id belongs to another company", %{conn: conn} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      {:ok, other_plugin} =
        Skills.create_plugin(%{
          identifier: "other-co-plugin",
          name: "Other Co Plugin",
          version: "1.0.0",
          manifest: %{},
          company_id: other_company.id
        })

      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      _html = render_click(view, "uninstall", %{"id" => other_plugin.id})

      assert Repo.get(Plugin, other_plugin.id) != nil
    end
  end

  describe "search event" do
    test "updates the search query and narrows the rendered list", %{conn: conn} do
      {:ok, view, html} = live(conn, "/plugins/marketplace")

      assert html =~ "Slack Notifications"
      assert html =~ "Jira Sync"

      narrowed = render_change(view, "search", %{"query" => "slack"})

      assert narrowed =~ "Slack Notifications"
      refute narrowed =~ "Jira Sync"
    end
  end
end
