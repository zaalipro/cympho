defmodule CymphoWeb.PluginLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Repo
  alias Cympho.Skills.Plugin

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

    test "shows plugin health diagnostics", %{conn: conn, current_company: company} do
      insert_plugin(company.id, %{name: "Capability Gap", enabled: true, capabilities: []})

      {:ok, view, html} = live(conn, "/plugins")

      assert has_element?(view, "[data-testid='plugin-health']")
      assert has_element?(view, "[data-testid='plugin-next-action']")
      assert html =~ "Plugin Health"
      assert html =~ "Watch"
      assert html =~ "Cap gaps"
      assert html =~ "Scope capabilities"
      assert html =~ "Next operator move"
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
