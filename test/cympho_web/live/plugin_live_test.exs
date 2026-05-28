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
    test "mounts and lists plugins for the current company", %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "Listed Plugin"})

      {:ok, _view, html} = live(conn, "/plugins")

      assert html =~ "Listed Plugin"
      assert html =~ plugin.identifier
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
    end

    test "submitting a valid form creates a plugin and redirects to its show page",
         %{conn: conn, current_company: company} do
      identifier = "form-create-#{System.unique_integer([:positive])}"

      {:ok, view, _html} = live(conn, "/plugins/new")

      params = %{
        "identifier" => identifier,
        "name" => "Form Created",
        "version" => "1.0.0",
        "manifest_json" => ~s({"entrypoint":"noop"}),
        "settings_json" => "{}",
        "capabilities" => "",
        "company_id" => company.id
      }

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_submit(view, "save", %{"plugin" => params})

      assert redirect_path =~ "/plugins/"

      assert {:ok, %Plugin{name: "Form Created", manifest: %{"entrypoint" => "noop"}}} =
               Cympho.Skills.get_plugin_by_identifier(identifier, company.id)
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
    end

    test "submitting a valid edit form updates the plugin and redirects",
         %{conn: conn, current_company: company} do
      plugin = insert_plugin(company.id, %{name: "Before"})

      {:ok, view, _html} = live(conn, "/plugins/#{plugin.id}/edit")

      params = %{
        "identifier" => plugin.identifier,
        "name" => "After",
        "version" => plugin.version,
        "manifest_json" => ~s({"entrypoint":"noop"}),
        "settings_json" => "{}",
        "capabilities" => ""
      }

      assert {:error, {:live_redirect, %{to: redirect_path}}} =
               render_submit(view, "save", %{"plugin" => params})

      assert redirect_path == "/plugins/#{plugin.id}"

      assert Repo.get!(Plugin, plugin.id).name == "After"
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
