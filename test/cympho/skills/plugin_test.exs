defmodule Cympho.Skills.PluginTest do
  use Cympho.DataCase, async: true

  alias Cympho.{Companies, Repo}
  alias Cympho.Skills.Plugin

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Plugin Schema Test",
        slug: "plugin-schema-#{System.unique_integer([:positive])}"
      })

    valid_attrs = %{
      identifier: "plugin-#{System.unique_integer([:positive])}",
      name: "Plugin",
      version: "1.0.0",
      manifest: %{"entrypoint" => "noop"},
      company_id: company.id
    }

    %{company: company, valid_attrs: valid_attrs}
  end

  describe "changeset/2 validate_required" do
    test "requires identifier", %{valid_attrs: attrs} do
      cs = Plugin.changeset(%Plugin{}, Map.delete(attrs, :identifier))

      refute cs.valid?
      assert %{identifier: ["can't be blank"]} = errors_on(cs)
    end

    test "requires name", %{valid_attrs: attrs} do
      cs = Plugin.changeset(%Plugin{}, Map.delete(attrs, :name))

      refute cs.valid?
      assert %{name: ["can't be blank"]} = errors_on(cs)
    end

    test "requires version", %{valid_attrs: attrs} do
      cs = Plugin.changeset(%Plugin{}, Map.delete(attrs, :version))

      refute cs.valid?
      assert %{version: ["can't be blank"]} = errors_on(cs)
    end

    test "manifest defaults to %{} so omitting it is allowed", %{valid_attrs: attrs} do
      attrs = Map.delete(attrs, :manifest)
      cs = Plugin.changeset(%Plugin{}, attrs)

      assert cs.valid?
    end
  end

  describe "changeset/2 validate_inclusion(:status, ...)" do
    test "accepts each canonical status value", %{valid_attrs: attrs} do
      for status <- ["installed", "active", "disabled", "error"] do
        attrs =
          attrs
          |> Map.put(:identifier, "ok-#{status}-#{System.unique_integer([:positive])}")
          |> Map.put(:status, status)

        cs = Plugin.changeset(%Plugin{}, attrs)
        assert cs.valid?, "expected status #{inspect(status)} to be accepted"
      end
    end

    test "rejects 'draft' (intentionally not in the canonical set)", %{valid_attrs: attrs} do
      attrs = Map.put(attrs, :status, "draft")
      cs = Plugin.changeset(%Plugin{}, attrs)

      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "rejects arbitrary strings", %{valid_attrs: attrs} do
      attrs = Map.put(attrs, :status, "anything")
      cs = Plugin.changeset(%Plugin{}, attrs)

      refute cs.valid?
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "changeset/2 unique_constraint" do
    test "rejects a duplicate (identifier, company_id) pair", %{
      valid_attrs: attrs,
      company: company
    } do
      assert {:ok, _} =
               %Plugin{}
               |> Plugin.changeset(attrs)
               |> Repo.insert()

      assert {:error, cs} =
               %Plugin{}
               |> Plugin.changeset(%{attrs | name: "Dup"})
               |> Repo.insert()

      assert %{identifier: ["has already been taken"]} = errors_on(cs)
      assert cs.changes.company_id == company.id
    end

    test "permits the same identifier in a different company", %{valid_attrs: attrs} do
      assert {:ok, _} =
               %Plugin{}
               |> Plugin.changeset(attrs)
               |> Repo.insert()

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Other Co",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      assert {:ok, _} =
               %Plugin{}
               |> Plugin.changeset(%{attrs | company_id: other_company.id, name: "Dup OK"})
               |> Repo.insert()
    end
  end

  describe "changeset/2 default field values" do
    test "status, enabled, manifest, settings, capabilities each have a default",
         %{valid_attrs: attrs} do
      {:ok, plugin} =
        %Plugin{}
        |> Plugin.changeset(attrs |> Map.delete(:manifest))
        |> Repo.insert()

      assert plugin.status == "installed"
      assert plugin.enabled == true
      assert plugin.manifest == %{}
      assert plugin.settings == %{}
      assert plugin.capabilities == []
      assert plugin.manifest_errors == %{}
    end
  end

  describe "changeset/2 manifest_errors field" do
    test "accepts an arbitrary map of error metadata", %{valid_attrs: attrs} do
      errors = %{"validation" => "version_pin_failed", "details" => %{"min" => "1.2.0"}}
      attrs = Map.put(attrs, :manifest_errors, errors)

      {:ok, plugin} =
        %Plugin{}
        |> Plugin.changeset(attrs)
        |> Repo.insert()

      assert plugin.manifest_errors == errors
    end
  end

  describe "changeset/2 partial-update behaviour" do
    test "skips status validation when the field is not in the changeset", %{valid_attrs: attrs} do
      {:ok, plugin} =
        %Plugin{}
        |> Plugin.changeset(attrs)
        |> Repo.insert()

      # Simulate a row that pre-dates the validation by directly forcing a non-canonical status,
      # then updating an unrelated field. The update SHOULD succeed because :status was not cast.
      plugin = %{plugin | status: "legacy-status"}

      cs = Plugin.changeset(plugin, %{name: "Renamed"})

      assert cs.valid?
      assert get_change(cs, :name) == "Renamed"
      refute Map.has_key?(cs.changes, :status)
    end
  end
end
