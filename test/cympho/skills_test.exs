defmodule Cympho.SkillsTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, Repo, Skills}
  alias Cympho.Skills.Plugin

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Skills Test Co",
        slug: "skills-test-#{System.unique_integer([:positive])}"
      })

    %{company: company}
  end

  defp insert_plugin(company_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          identifier: "plugin-#{System.unique_integer([:positive])}",
          name: "Plugin #{System.unique_integer([:positive])}",
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

  describe "list_plugins/1" do
    test "returns plugins scoped to the given company", %{company: company} do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      mine = insert_plugin(company.id)
      _theirs = insert_plugin(other_company.id)

      result = Skills.list_plugins(company_id: company.id)

      assert Enum.map(result, & &1.id) == [mine.id]
    end

    test "filters by status", %{company: company} do
      _installed = insert_plugin(company.id, %{status: "installed"})
      active = insert_plugin(company.id, %{status: "active"})

      result = Skills.list_plugins(company_id: company.id, status: "active")

      assert Enum.map(result, & &1.id) == [active.id]
    end

    test "preloads company and project associations", %{company: company} do
      _plugin = insert_plugin(company.id)

      [loaded] = Skills.list_plugins(company_id: company.id)

      assert %Cympho.Companies.Company{id: cid} = loaded.company
      assert cid == company.id
    end

    test "returns all plugins across companies when no opts are given", %{company: company} do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      mine = insert_plugin(company.id)
      theirs = insert_plugin(other_company.id)

      ids =
        Skills.list_plugins()
        |> Enum.map(& &1.id)
        |> MapSet.new()

      assert MapSet.member?(ids, mine.id)
      assert MapSet.member?(ids, theirs.id)
    end

    test "orders by plugin name ascending", %{company: company} do
      _zeta = insert_plugin(company.id, %{name: "Zeta"})
      _alpha = insert_plugin(company.id, %{name: "Alpha"})
      _middle = insert_plugin(company.id, %{name: "Middle"})

      names =
        Skills.list_plugins(company_id: company.id)
        |> Enum.map(& &1.name)

      assert names == ["Alpha", "Middle", "Zeta"]
    end
  end

  describe "get_company_plugin/2" do
    test "returns the plugin scoped to the given company", %{company: company} do
      plugin = insert_plugin(company.id)

      assert {:ok, %Plugin{id: id}} = Skills.get_company_plugin(company.id, plugin.id)
      assert id == plugin.id
    end

    test "returns :not_found when the plugin belongs to a different company", %{company: company} do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      plugin = insert_plugin(other_company.id)

      assert {:error, :not_found} = Skills.get_company_plugin(company.id, plugin.id)
    end

    test "returns :not_found when the ID does not exist anywhere", %{company: company} do
      assert {:error, :not_found} =
               Skills.get_company_plugin(company.id, "00000000-0000-0000-0000-000000000000")
    end

    test "preloads the company association on the returned plugin", %{company: company} do
      plugin = insert_plugin(company.id)
      company_id = company.id

      {:ok, loaded} = Skills.get_company_plugin(company.id, plugin.id)

      assert %Cympho.Companies.Company{id: ^company_id} = loaded.company
    end
  end

  describe "get_plugin_by_identifier/2" do
    test "returns the plugin scoped by identifier and company", %{company: company} do
      plugin = insert_plugin(company.id, %{identifier: "lookup-target"})

      assert {:ok, %Plugin{id: id}} = Skills.get_plugin_by_identifier("lookup-target", company.id)
      assert id == plugin.id
    end

    test "returns :not_found when the identifier exists in another company", %{company: company} do
      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      _plugin = insert_plugin(other_company.id, %{identifier: "private"})

      assert {:error, :not_found} = Skills.get_plugin_by_identifier("private", company.id)
    end

    test "returns :not_found when the identifier does not exist anywhere", %{company: company} do
      assert {:error, :not_found} = Skills.get_plugin_by_identifier("ghost", company.id)
    end
  end

  describe "create_plugin/1" do
    test "inserts a plugin with valid attrs", %{company: company} do
      assert {:ok, %Plugin{} = plugin} =
               Skills.create_plugin(%{
                 identifier: "new-plugin",
                 name: "New",
                 version: "1.0.0",
                 manifest: %{"entrypoint" => "x"},
                 company_id: company.id
               })

      assert plugin.identifier == "new-plugin"
    end

    test "returns {:error, %Ecto.Changeset{}} when required fields are missing", %{company: company} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Skills.create_plugin(%{company_id: company.id})

      assert %{identifier: _, name: _, version: _} = errors_on(cs)
    end

    test "rejects an invalid status value", %{company: company} do
      assert {:error, %Ecto.Changeset{} = cs} =
               Skills.create_plugin(%{
                 identifier: "bad-status",
                 name: "X",
                 version: "1.0.0",
                 manifest: %{},
                 status: "not-a-status",
                 company_id: company.id
               })

      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "honors the (identifier, company_id) unique constraint", %{company: company} do
      _existing = insert_plugin(company.id, %{identifier: "unique-id"})

      assert {:error, %Ecto.Changeset{} = cs} =
               Skills.create_plugin(%{
                 identifier: "unique-id",
                 name: "Dup",
                 version: "1.0.0",
                 manifest: %{},
                 company_id: company.id
               })

      assert %{identifier: ["has already been taken"]} = errors_on(cs)
    end

    test "sets default status, enabled, and manifest when omitted", %{company: company} do
      assert {:ok, plugin} =
               Skills.create_plugin(%{
                 identifier: "defaults-only",
                 name: "Defaults",
                 version: "1.0.0",
                 manifest: %{},
                 company_id: company.id
               })

      assert plugin.status == "installed"
      assert plugin.enabled == true
      assert plugin.manifest == %{}
      assert plugin.settings == %{}
      assert plugin.capabilities == []
    end

    test "accepts each canonical status value", %{company: company} do
      for status <- ["installed", "active", "disabled", "error"] do
        assert {:ok, plugin} =
                 Skills.create_plugin(%{
                   identifier: "status-#{status}-#{System.unique_integer([:positive])}",
                   name: "S",
                   version: "1.0.0",
                   manifest: %{},
                   status: status,
                   company_id: company.id
                 })

        assert plugin.status == status
      end
    end
  end

  describe "delete_plugin/1" do
    test "removes the plugin", %{company: company} do
      plugin = insert_plugin(company.id)

      assert {:ok, %Plugin{}} = Skills.delete_plugin(plugin)
      assert Repo.get(Plugin, plugin.id) == nil
    end
  end

  describe "toggle_plugin/1" do
    test "flips enabled and syncs status to 'disabled'", %{company: company} do
      plugin = insert_plugin(company.id, %{enabled: true, status: "active"})

      assert {:ok, %Plugin{enabled: false, status: "disabled"}} = Skills.toggle_plugin(plugin)
    end

    test "flips enabled back to true and syncs status to 'active'", %{company: company} do
      plugin = insert_plugin(company.id, %{enabled: false, status: "disabled"})

      assert {:ok, %Plugin{enabled: true, status: "active"}} = Skills.toggle_plugin(plugin)
    end

    test "from 'error' status with enabled=true, flips to disabled", %{company: company} do
      plugin = insert_plugin(company.id, %{enabled: true, status: "error"})

      assert {:ok, %Plugin{enabled: false, status: "disabled"}} = Skills.toggle_plugin(plugin)
    end
  end

  describe "update_plugin_settings/2" do
    test "merges new settings into existing ones", %{company: company} do
      plugin = insert_plugin(company.id, %{settings: %{"foo" => 1, "bar" => 2}})

      assert {:ok, %Plugin{settings: settings}} =
               Skills.update_plugin_settings(plugin, %{"bar" => 99, "baz" => 3})

      assert settings == %{"foo" => 1, "bar" => 99, "baz" => 3}
    end

    test "treats a nil current settings map as empty before merging", %{company: company} do
      plugin = insert_plugin(company.id, %{settings: %{}})
      plugin = %{plugin | settings: nil}

      assert {:ok, %Plugin{settings: settings}} =
               Skills.update_plugin_settings(plugin, %{"new" => "value"})

      assert settings == %{"new" => "value"}
    end

    test "preserves existing keys not present in the update", %{company: company} do
      plugin = insert_plugin(company.id, %{settings: %{"keep" => 1, "swap" => 2}})

      assert {:ok, %Plugin{settings: settings}} =
               Skills.update_plugin_settings(plugin, %{"swap" => 99})

      assert settings == %{"keep" => 1, "swap" => 99}
    end
  end

  describe "change_plugin/2" do
    test "returns a changeset without persisting", %{company: company} do
      plugin = insert_plugin(company.id)

      cs = Skills.change_plugin(plugin, %{name: "Renamed"})

      assert %Ecto.Changeset{valid?: true} = cs
      assert get_change(cs, :name) == "Renamed"
    end

    test "returns an identity changeset when called with no attrs", %{company: company} do
      plugin = insert_plugin(company.id)

      cs = Skills.change_plugin(plugin)

      assert %Ecto.Changeset{valid?: true, changes: changes} = cs
      assert changes == %{}
    end

    test "returns an invalid changeset for an out-of-range status", %{company: company} do
      plugin = insert_plugin(company.id)

      cs = Skills.change_plugin(plugin, %{status: "bogus"})

      assert %Ecto.Changeset{valid?: false} = cs
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "update_skill_status/2" do
    test "updates the status to a canonical value", %{company: company} do
      plugin = insert_plugin(company.id, %{status: "installed"})

      assert {:ok, %Plugin{status: "active"}} = Skills.update_skill_status(plugin, "active")
    end

    test "accepts each of the four canonical statuses", %{company: company} do
      for status <- ["installed", "active", "disabled", "error"] do
        plugin = insert_plugin(company.id)

        assert {:ok, %Plugin{status: ^status}} = Skills.update_skill_status(plugin, status)
      end
    end

    test "returns {:error, changeset} for 'draft' (guard-listed but changeset-rejected)",
         %{company: company} do
      plugin = insert_plugin(company.id, %{status: "installed"})

      assert {:error, %Ecto.Changeset{} = cs} = Skills.update_skill_status(plugin, "draft")
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "raises FunctionClauseError for a non-guard-listed status", %{company: company} do
      plugin = insert_plugin(company.id)

      assert_raise FunctionClauseError, fn ->
        Skills.update_skill_status(plugin, "anything-else")
      end
    end

    test "raises FunctionClauseError for a non-string status", %{company: company} do
      plugin = insert_plugin(company.id)

      assert_raise FunctionClauseError, fn ->
        Skills.update_skill_status(plugin, :active)
      end
    end
  end
end
