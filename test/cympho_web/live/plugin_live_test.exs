defmodule CymphoWeb.PluginLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Repo
  alias Cympho.Skills.Plugin

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

  defp insert_plugin(company_id, overrides) do
    attrs =
      Map.merge(
        %{
          identifier: "plugin-#{System.unique_integer([:positive])}",
          name: "Test Plugin",
          version: "1.0.0",
          manifest: %{"entrypoint" => "noop"},
          status: "installed",
          company_id: company_id
        },
        overrides
      )

    %Plugin{}
    |> Plugin.changeset(attrs)
    |> Repo.insert!()
  end

  describe "PluginLive.Index" do
    test "renders an actionable empty state before plugins are installed", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ ~s(data-testid="plugins-empty")
      assert html =~ "No runtime plugins installed yet"
      assert html =~ "Install one tightly scoped extension"
      assert html =~ "Browse marketplace"
      assert html =~ "New plugin"
      refute html =~ "Clear filters"
    end

    test "mounts and lists plugins for the current company", %{
      conn: conn,
      current_company: company
    } do
      plugin = insert_plugin(company.id, %{name: "Listed Plugin"})

      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "Listed Plugin"
      assert html =~ plugin.identifier
    end

    test "defaults to current company and never lists foreign-tenant plugins", %{
      conn: conn,
      current_company: company
    } do
      own = insert_plugin(company.id, %{name: "Own Company Plugin"})

      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Plugin Co",
          slug: "foreign-plugin-#{System.unique_integer([:positive])}"
        })

      foreign = insert_plugin(foreign_company.id, %{name: "Foreign Tenant Plugin"})

      {:ok, view, html} = live(conn, "/plugins")

      assert html =~ own.name
      refute html =~ foreign.name
      # Company filter is membership-only (no global "All companies" unscoped option).
      refute html =~ "All companies"
      refute html =~ foreign_company.name
      assert has_element?(view, "option[value='#{company.id}']")
    end

    test "company filter only accepts membership companies; unknown falls back to current", %{
      conn: conn,
      current_company: company
    } do
      own = insert_plugin(company.id, %{name: "Current Scoped Plugin"})

      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Unrelated Plugin Co",
          slug: "unrelated-plugin-#{System.unique_integer([:positive])}"
        })

      foreign = insert_plugin(foreign_company.id, %{name: "Unrelated Tenant Plugin"})

      {:ok, _view, html} = live(conn, "/plugins?company_id=#{foreign_company.id}")

      assert html =~ own.name
      refute html =~ foreign.name
    end

    test "hides mutation controls for a plugin outside the current company", %{conn: conn} do
      user_id = Plug.Conn.get_session(conn, :user_id)

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Plugin Company",
          slug: "other-plugin-company-#{System.unique_integer([:positive])}"
        })

      assert {:ok, _membership} =
               Companies.create_membership(%{
                 user_id: user_id,
                 company_id: other_company.id,
                 role: "admin"
               })

      plugin = insert_plugin(other_company.id, %{name: "Other Company Plugin"})

      {:ok, view, html} = live(conn, "/plugins?company_id=#{other_company.id}")

      assert html =~ plugin.name
      refute has_element?(view, "button[phx-click='toggle_plugin'][phx-value-id='#{plugin.id}']")
      refute has_element?(view, "a[href='/plugins/#{plugin.id}/edit']")
      refute has_element?(view, "button[phx-click='delete'][phx-value-id='#{plugin.id}']")
      assert has_element?(view, "a[href='/plugins/#{plugin.id}/settings']")
    end

    test "shows plugin health diagnostics", %{conn: conn, current_company: company} do
      insert_plugin(company.id, %{name: "Capability Gap", enabled: true, capabilities: []})

      {:ok, view, html} = live(conn, "/plugins")

      assert has_element?(view, "[data-testid='plugin-health']")
      assert has_element?(view, "[data-testid='plugin-next-action']")
      assert html =~ "Plugin Health"
      assert html =~ "Watch"
      assert html =~ "Capability gaps"
      assert html =~ "Scope capabilities"
      assert html =~ "Do this next"
      refute html =~ "Next operator move"
      assert html =~ "Open plugin settings"
    end

    test "filter event narrows the list by status", %{conn: conn, current_company: company} do
      _installed = insert_plugin(company.id, %{name: "Installed Only", status: "installed"})
      _active = insert_plugin(company.id, %{name: "Active Only", status: "active"})

      {:ok, view, _html} = live(conn, "/plugins")

      html =
        view
        |> render_change("filter", %{"company_id" => company.id, "status" => "active"})

      assert html =~ "Active Only"
      refute html =~ "Installed Only"
    end

    test "query status filter narrows the initial list", %{conn: conn, current_company: company} do
      _installed = insert_plugin(company.id, %{name: "Query Installed", status: "installed"})
      _error = insert_plugin(company.id, %{name: "Query Error", status: "error"})

      {:ok, _view, html} = live(conn, "/plugins?status=error")

      assert html =~ "Query Error"
      refute html =~ "Query Installed"
    end

    test "filtered empty state explains how to recover", %{conn: conn, current_company: company} do
      _installed = insert_plugin(company.id, %{name: "Installed But Hidden", status: "installed"})

      {:ok, _view, html} = live(conn, "/plugins?status=error")

      assert html =~ ~s(data-testid="plugins-empty")
      assert html =~ "No plugins match these filters"
      assert html =~ "Clear filters to return to the full extension inventory"
      assert html =~ "Clear filters"
      assert html =~ "Browse marketplace"
      assert html =~ "New plugin"
      refute html =~ "Installed But Hidden"
    end
  end

  describe "PluginLive.Index toggle" do
    test "toggle_plugin event flips enabled and updates status via the Skills context",
         %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{enabled: true, status: "active"})

      {:ok, view, _html} = live(conn, "/plugins")

      _html = render_click(view, "toggle_plugin", %{"id" => plugin.id})

      updated = Repo.get!(Plugin, plugin.id)
      assert updated.enabled == false
      assert updated.status == "disabled"
    end

    test "delete event removes the plugin row via the Skills context",
         %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "To Delete"})

      {:ok, view, _html} = live(conn, "/plugins")

      _html = render_click(view, "delete", %{"id" => plugin.id})

      assert Repo.get(Plugin, plugin.id) == nil
    end

    test "toggle_plugin event is a no-op when the id belongs to another company",
         %{conn: conn, current_company: company} do
      {:ok, other_company} =
        Cympho.Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      other_plugin = insert_plugin(other_company.id, %{enabled: true, status: "active"})

      _user_company_plugin = insert_plugin(company.id, %{})
      {:ok, view, _html} = live(conn, "/plugins")

      _html = render_click(view, "toggle_plugin", %{"id" => other_plugin.id})

      unchanged = Repo.get!(Plugin, other_plugin.id)
      assert unchanged.enabled == true
      assert unchanged.status == "active"
    end

    @tag regular_member: true
    test "regular members cannot see or invoke plugin mutations", %{
      conn: conn,
      current_company: company
    } do
      plugin = insert_plugin(company.id, %{enabled: true, status: "active"})

      {:ok, view, html} = live(conn, "/plugins")

      refute has_element?(view, ~s(a[href="/plugins/new"]))
      refute has_element?(view, ~s(button[phx-click="toggle_plugin"]))
      refute has_element?(view, ~s(a[href="/plugins/#{plugin.id}/edit"]))
      refute has_element?(view, ~s(button[phx-click="delete"]))
      refute html =~ "New Plugin"

      render_click(view, "toggle_plugin", %{"id" => plugin.id})
      render_click(view, "delete", %{"id" => plugin.id})

      unchanged = Repo.get!(Plugin, plugin.id)
      assert unchanged.enabled
      assert unchanged.status == "active"

      assert {:error, {:live_redirect, %{to: "/plugins"}}} = live(conn, "/plugins/new")

      assert {:error, {:live_redirect, %{to: "/plugins"}}} =
               live(conn, "/plugins/#{plugin.id}/edit")
    end

    @tag membership_role: "member", board_member: true
    test "member board users can create and manage plugins", %{
      conn: conn,
      current_company: company
    } do
      plugin = insert_plugin(company.id, %{enabled: true, status: "active"})

      {:ok, view, _html} = live(conn, "/plugins")

      assert has_element?(view, ~s(a[href="/plugins/new"]))
      assert has_element?(view, ~s(button[phx-click="toggle_plugin"]))
      assert {:ok, _new_view, _html} = live(conn, "/plugins/new")

      render_click(view, "toggle_plugin", %{"id" => plugin.id})
      refute Repo.get!(Plugin, plugin.id).enabled
    end

    @tag membership_role: "viewer", board_member: true
    test "a board flag does not make a viewer a plugin manager", %{
      conn: conn,
      current_company: company
    } do
      plugin = insert_plugin(company.id, %{enabled: true, status: "active"})

      {:ok, view, _html} = live(conn, "/plugins")

      refute has_element?(view, ~s(a[href="/plugins/new"]))
      refute has_element?(view, ~s(button[phx-click="toggle_plugin"]))
      assert {:error, {:live_redirect, %{to: "/plugins"}}} = live(conn, "/plugins/new")

      render_click(view, "toggle_plugin", %{"id" => plugin.id})
      assert Repo.get!(Plugin, plugin.id).enabled
    end
  end

  describe "PluginLive.Show" do
    test "keeps owner mutation controls in Advanced mode", %{
      conn: conn,
      current_company: company
    } do
      plugin = insert_plugin(company.id, %{name: "Advanced Controls"})

      {:ok, view, _html} = live(conn, "/plugins/#{plugin.id}")

      assert has_element?(view, "a.ui-advanced-only[href='/plugins/#{plugin.id}/edit']")
      assert has_element?(view, "button.ui-advanced-only[phx-click='toggle_plugin']")
      assert has_element?(view, "button[phx-click='toggle_plugin'][data-confirm]")
    end

    test "shows a plain-language Simple overview and scopes raw metadata to Advanced mode", %{
      conn: conn,
      current_company: company
    } do
      plugin =
        insert_plugin(company.id, %{
          name: "Scoped Capability Plugin",
          enabled: true,
          capabilities: ["read:issues"],
          manifest: %{"host_services" => ["read:issues"]}
        })

      {:ok, view, _html} = live(conn, "/plugins/#{plugin.id}")

      assert has_element?(view, "[data-testid='plugin-simple-overview'].ui-simple-only")
      assert has_element?(view, "[data-testid='plugin-simple-overview']", "Enabled")
      assert has_element?(view, "[data-testid='plugin-simple-overview']", company.name)

      assert has_element?(
               view,
               "[data-testid='plugin-simple-overview']",
               "This plugin can read issues."
             )

      refute has_element?(view, "[data-testid='plugin-simple-overview']", "read:issues")

      assert has_element?(
               view,
               "[data-testid='plugin-advanced-detail'].ui-advanced-only pre",
               "read:issues"
             )
    end
  end

  describe "PluginLive.New" do
    test "mounts the new-plugin form", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/plugins/new")

      assert html =~ "New Plugin"
      assert html =~ "Plugin launch plan"
      assert html =~ "Runtime manifest"
      assert html =~ "Project scope"
      assert html =~ "Advanced manifest JSON"
      assert html =~ ~s(data-testid="plugin-setup-checklist")
    end

    test "submitting a guided form creates a company-scoped plugin and redirects to its show page",
         %{conn: conn, current_company: company} do
      identifier = "form-create-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/plugins/new")

      params = %{
        "identifier" => identifier,
        "name" => "Form Created",
        "version" => "1.0.0",
        "entrypoint" => "Cympho.Plugins.FormCreated",
        "manifest_json" => ~s({"host_services":["issues"]}),
        "settings_json" => ~s({"mode":"review"}),
        "capabilities" => "tool_access, issue_write",
        "project_id" => ""
      }

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_submit(view, "save", %{"plugin" => params})

      assert redirect_path =~ "/plugins/"

      assert {:ok, %Plugin{} = plugin} =
               Cympho.Skills.get_plugin_by_identifier(identifier, company.id)

      assert plugin.name == "Form Created"
      assert plugin.company_id == company.id
      assert plugin.manifest["entrypoint"] == "Cympho.Plugins.FormCreated"
      assert plugin.manifest["host_services"] == ["issues"]
      assert plugin.manifest["capabilities"] == ["tool_access", "issue_write"]
      assert plugin.settings == %{"mode" => "review"}
      assert plugin.capabilities == ["tool_access", "issue_write"]
    end

    test "submitting an invalid form re-renders with errors, no row created",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/plugins/new")

      params = %{
        "identifier" => "",
        "name" => "",
        "version" => "",
        "manifest_json" => "{}",
        "settings_json" => "{}",
        "capabilities" => ""
      }

      html = render_submit(view, "save", %{"plugin" => params})

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Repo.all(Plugin) == []
    end
  end

  describe "PluginLive.Edit" do
    test "mounts and edits an existing plugin", %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "Original"})

      {:ok, _view, html} = live(conn, "/plugins/#{plugin.id}/edit")

      assert html =~ "Original"
      assert html =~ "Plugin capability plan"
      assert html =~ "Advanced manifest JSON"
      assert html =~ ~s(data-testid="plugin-setup-checklist")
    end

    test "submitting a valid edit form updates manifest, capabilities, and redirects",
         %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "Before", manifest: %{"entrypoint" => "old"}})

      {:ok, view, _html} = live(conn, "/plugins/#{plugin.id}/edit")

      params = %{
        "identifier" => plugin.identifier,
        "name" => "After",
        "version" => plugin.version,
        "entrypoint" => "Cympho.Plugins.After",
        "manifest_json" => ~s({"host_services":["documents"]}),
        "settings_json" => "{}",
        "capabilities" => "document_write"
      }

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_submit(view, "save", %{"plugin" => params})

      assert redirect_path == "/plugins/#{plugin.id}"

      updated = Repo.get!(Plugin, plugin.id)
      assert updated.name == "After"
      assert updated.manifest["entrypoint"] == "Cympho.Plugins.After"
      assert updated.manifest["host_services"] == ["documents"]
      assert updated.capabilities == ["document_write"]
    end

    test "submitting an invalid edit form re-renders with errors",
         %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "Before"})

      {:ok, view, _html} = live(conn, "/plugins/#{plugin.id}/edit")

      params = %{
        "identifier" => "",
        "name" => "After",
        "version" => "1.0.0",
        "manifest_json" => "{}",
        "settings_json" => "{}",
        "capabilities" => ""
      }

      html = render_submit(view, "save", %{"plugin" => params})

      assert html =~ "can&#39;t be blank" or html =~ "can't be blank"
      assert Repo.get!(Plugin, plugin.id).name == "Before"
    end
  end
end
