defmodule CymphoWeb.PluginMarketplaceLiveTest do
  use CymphoWeb.LiveCase, async: false

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Skills
  alias Cympho.Skills.Plugin
  alias Cympho.Plugins.Runtime

  import CymphoWeb.R3PageHelpers

  setup %{conn: conn, current_company: company} = context do
    user_id = Plug.Conn.get_session(conn, :user_id)
    membership = Companies.get_membership(user_id, company.id)

    role = context[:membership_role] || if(context[:regular_member], do: "member", else: "admin")

    assert {:ok, _membership} =
             Companies.update_membership(membership, %{
               role: role,
               is_board_member: context[:board_member] == true
             })

    :ok
  end

  describe "mount" do
    test "renders the available plugins catalog", %{conn: conn} do
      {:ok, view, html} = live(conn, "/plugins/marketplace")

      assert html =~ "Plugin catalog"
      # The entry count was stated in the page eyebrow, a section eyebrow, and a
      # stat tile; r3 (v7 H12) says it once, in the head's line.
      refute html =~ "source-backed entries"
      doc = main_doc(view)
      assert text(doc, ".head .sub") == "3 catalog entries · 1 installable · 0 installed"

      assert_r3_page(doc,
        page: "marketplace",
        h1: "Plugin catalog",
        kind: :deep,
        parent: "Plugins",
        primaries: 0
      )

      assert length(Floki.find(doc, ~s(.mk-grid > .card[data-testid="plugin-catalog-entry"]))) ==
               3

      assert Floki.find(doc, ~s(form[phx-change="search"] input[name="query"])) != []
      refute html =~ "ember-"
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

    @tag membership_role: "member", board_member: true
    test "member board users can install marketplace plugins", %{
      conn: conn,
      current_company: company
    } do
      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      assert has_element?(view, "button[phx-click='install']")
      render_click(view, "install", %{"identifier" => "example-plugin"})

      assert {:ok, %Plugin{} = plugin} =
               Skills.get_plugin_by_identifier("example-plugin", company.id)

      assert :ok = Runtime.stop_plugin(plugin)
    end
  end

  describe "head counts" do
    test "installed counts the catalog entries this company installed, not its other plugins",
         %{conn: conn, current_company: company} do
      entry = Enum.find(Cympho.Plugins.Catalog.entries(), & &1.installable?)
      assert {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)

      {:ok, _custom} =
        Skills.create_plugin(%{
          identifier: "custom-not-in-catalog",
          name: "Custom",
          version: "1.0.0",
          manifest: %{},
          company_id: company.id
        })

      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      # One card says Installed, so the line says 1 (it said 2: every company plugin).
      assert text(main_doc(view), ".head .sub") ==
               "3 catalog entries · 1 installable · 1 installed"

      assert :ok = Runtime.stop_plugin(plugin)
    end
  end

  describe "Remove on an installed entry" do
    test "managers can remove an installed catalog plugin from its card", %{
      conn: conn,
      current_company: company
    } do
      entry = Enum.find(Cympho.Plugins.Catalog.entries(), & &1.installable?)
      assert {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)

      {:ok, view, _html} = live(conn, "/plugins/marketplace")
      card = ~s([data-plugin-identifier="#{entry.identifier}"])

      assert has_element?(view, card, "Installed")
      refute has_element?(view, "#{card} button[phx-click='install']")

      assert [confirm] =
               main_doc(view)
               |> Floki.attribute(
                 ~s(#{card} button.pl.warn[phx-click="uninstall"][phx-value-id="#{plugin.id}"]),
                 "data-confirm"
               )

      assert confirm == "Remove #{entry.name}?"

      view |> element(~s(#{card} button[phx-click="uninstall"])) |> render_click()

      assert {:error, :not_found} = Skills.get_plugin_by_identifier(entry.identifier, company.id)
      assert text(main_doc(view), ".flash-line .flash-msg") == "Plugin uninstalled successfully"
    end

    @tag regular_member: true
    test "regular members see the installed state without Remove", %{
      conn: conn,
      current_company: company
    } do
      entry = Enum.find(Cympho.Plugins.Catalog.entries(), & &1.installable?)
      assert {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)

      {:ok, view, _html} = live(conn, "/plugins/marketplace")

      assert has_element?(view, ~s([data-plugin-identifier="#{entry.identifier}"]), "Installed")
      refute has_element?(view, ~s(button[phx-click="uninstall"]))
      assert :ok = Runtime.stop_plugin(plugin)
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
