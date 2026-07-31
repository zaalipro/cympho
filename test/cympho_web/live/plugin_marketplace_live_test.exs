defmodule CymphoWeb.PluginMarketplaceLiveTest do
  use CymphoWeb.LiveCase, async: false

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Skills
  alias Cympho.Skills.Plugin
  alias Cympho.Plugins.Runtime

  setup %{conn: conn, current_company: company} = context do
    unless context[:regular_member] do
      user_id = Plug.Conn.get_session(conn, :user_id)
      membership = Companies.get_membership(user_id, company.id)
      assert {:ok, _membership} = Companies.update_membership(membership, %{role: "admin"})
    end

    :ok
  end

  describe "mount" do
    test "renders the available plugins catalog", %{conn: conn} do
      {:ok, view, html} = live(conn, "/plugins/marketplace")

      assert html =~ "Plugin Catalog"
      assert html =~ "source-backed entries"
      assert html =~ "GitHub Integration"
      assert html =~ "Custom Webhooks"
      assert html =~ "Plugin SDK Example"
      assert has_element?(view, "[data-testid='plugin-catalog-source']")

      marketplace_html = render(view)
      refute marketplace_html =~ "docs.cympho.com"
      refute marketplace_html =~ ~s(title="Installs")
      refute marketplace_html =~ "1247"
      refute marketplace_html =~ "4.8"
    end

    test "shows install actions only for installable source entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      assert has_element?(
               view,
               "[data-plugin-identifier='example-plugin'] button[phx-click='install']"
             )

      refute has_element?(
               view,
               "[data-plugin-identifier='github-integration'] button[phx-click='install']"
             )

      refute has_element?(
               view,
               "[data-plugin-identifier='custom-webhook'] button[phx-click='install']"
             )

      assert has_element?(
               view,
               "[data-plugin-identifier='github-integration'] [data-testid='plugin-catalog-not-installable']"
             )
    end
  end

  describe "install event" do
    test "creates a Skills.Plugin row scoped to the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      _html = render_click(view, "install", %{"identifier" => "example-plugin"})

      assert {:ok, %Plugin{} = plugin} =
               Skills.get_plugin_by_identifier("example-plugin", company.id)

      assert plugin.name == "Plugin SDK Example"
      assert plugin.status == "active"
      assert plugin.enabled == true
      assert plugin.manifest["source"] == "local_catalog"
      assert plugin.manifest["entrypoint"] == "Cympho.Plugins.ExamplePlugin"
      assert plugin.manifest["capabilities"] == ["read:issues"]
      assert is_pid(Runtime.whereis(plugin))

      assert has_element?(
               view,
               "[data-plugin-identifier='example-plugin']",
               "Installed"
             )

      refute has_element?(
               view,
               "[data-plugin-identifier='example-plugin'] button[phx-click='install']"
             )

      assert :ok = Runtime.stop_plugin(plugin)
    end

    test "is a no-op when the identifier is not in the available catalog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      _html = render_click(view, "install", %{"identifier" => "does-not-exist"})

      assert Repo.all(Plugin) == []
    end

    test "is a no-op for a source reference that is not installable", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      render_click(view, "install", %{"identifier" => "github-integration"})

      assert {:error, :not_found} =
               Skills.get_plugin_by_identifier("github-integration", company.id)
    end

    @tag regular_member: true
    test "regular members cannot install marketplace plugins", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, html} = live(conn, "/plugins/marketplace")

      assert html =~ ~s(data-testid="plugin-marketplace-read-only")
      refute has_element?(view, "button[phx-click='install']")

      render_click(view, "install", %{"identifier" => "example-plugin"})

      assert {:error, :not_found} =
               Skills.get_plugin_by_identifier("example-plugin", company.id)
    end
  end

  describe "uninstall event" do
    test "stops the supervised worker before deleting a catalog plugin", %{
      conn: conn,
      current_company: company
    } do
      entry = Enum.find(Cympho.Plugins.Catalog.entries(), & &1.installable?)
      assert {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)
      pid = Runtime.whereis(plugin)
      assert is_pid(pid)

      {:ok, view, _html} = live(conn, "/plugins/marketplace")
      _html = render_click(view, "uninstall", %{"id" => plugin.id})

      refute Process.alive?(pid)
      assert {:error, :not_found} = Skills.get_plugin_by_identifier(entry.identifier, company.id)
    end

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

      assert html =~ "GitHub Integration"
      assert html =~ "Plugin SDK Example"

      narrowed = render_change(view, "search", %{"query" => "webhook"})

      assert narrowed =~ "Custom Webhooks"
      refute narrowed =~ "Plugin SDK Example"
    end
  end
end
