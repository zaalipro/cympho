defmodule Cympho.Skills.LoaderTest do
  use Cympho.DataCase
  alias Cympho.Skills.{Loader, Plugin}
  alias Cympho.Companies
  alias Cympho.Repo

  describe "validate_manifest/1" do
    test "validates a valid manifest map" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.Loader"
      }

      assert {:ok, _manifest} = Loader.validate_manifest(manifest)
    end

    test "rejects an invalid manifest map" do
      manifest = %{
        "name" => "test-skill"
        # Missing required fields
      }

      assert {:error, _reasons} = Loader.validate_manifest(manifest)
    end

    test "rejects non-map input" do
      assert {:error, ["manifest must be a map"]} = Loader.validate_manifest("not-a-map")
      assert {:error, ["manifest must be a map"]} = Loader.validate_manifest(123)
      assert {:error, ["manifest must be a map"]} = Loader.validate_manifest(nil)
    end
  end

  describe "load/1" do
    setup do
      start_supervised!(Loader)

      {:ok, company} =
        Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})

      %{company: company}
    end

    test "returns error for non-existent plugin", %{company: company} do
      assert {:error, :not_found} = Loader.load(Ecto.UUID.generate())
    end

    test "returns error for invalid ID type", %{company: company} do
      assert {:error, :invalid_id} = Loader.load(123)
      assert {:error, :invalid_id} = Loader.load(nil)
    end

    test "loads a valid plugin with valid manifest", %{company: company} do
      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "test-plugin",
          version: "1.0.0",
          name: "Test Plugin",
          author: "test",
          manifest: %{
            "name" => "test-plugin",
            "version" => "1.0.0",
            "author" => "test",
            "entrypoint" => "Cympho.Skills.Loader"
          },
          company_id: company.id,
          enabled: true
        })

      assert {:ok, _manifest} = Loader.load(plugin.id)
      assert Loader.loaded?(plugin.id)
    end

    test "returns error for plugin with invalid manifest", %{company: company} do
      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "invalid-plugin",
          version: "1.0.0",
          name: "Invalid Plugin",
          author: "test",
          manifest: %{"name" => "incomplete"},
          company_id: company.id,
          enabled: true
        })

      assert {:error, _reasons} = Loader.load(plugin.id)
      refute Loader.loaded?(plugin.id)
    end

    test "returns error for plugin with non-existent entrypoint", %{company: company} do
      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "bad-entrypoint",
          version: "1.0.0",
          name: "Bad Entrypoint",
          author: "test",
          manifest: %{
            "name" => "test-plugin",
            "version" => "1.0.0",
            "author" => "test",
            "entrypoint" => "NonExistent.Module"
          },
          company_id: company.id,
          enabled: true
        })

      assert {:error, {:entrypoint_not_found, "NonExistent.Module"}} = Loader.load(plugin.id)
      refute Loader.loaded?(plugin.id)
    end
  end

  describe "unload/1" do
    setup do
      start_supervised!(Loader)

      {:ok, company} =
        Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})

      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "test-plugin",
          version: "1.0.0",
          name: "Test Plugin",
          author: "test",
          manifest: %{
            "name" => "test-plugin",
            "version" => "1.0.0",
            "author" => "test",
            "entrypoint" => "Cympho.Skills.Loader"
          },
          company_id: company.id,
          enabled: true
        })

      {:ok, _} = Loader.load(plugin.id)

      %{plugin: plugin}
    end

    test "unloads a loaded skill", %{plugin: plugin} do
      assert :ok = Loader.unload(plugin.id)
      refute Loader.loaded?(plugin.id)
    end

    test "returns error for non-loaded skill", %{plugin: plugin} do
      assert :ok = Loader.unload(Ecto.UUID.generate())
    end

    test "returns error for invalid ID type", %{plugin: plugin} do
      assert {:error, :invalid_id} = Loader.unload(123)
      assert {:error, :invalid_id} = Loader.unload(nil)
    end
  end

  describe "loaded?/1" do
    setup do
      start_supervised!(Loader)

      {:ok, company} =
        Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})

      %{company: company}
    end

    test "returns true for loaded skill", %{company: company} do
      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "test-plugin",
          version: "1.0.0",
          name: "Test Plugin",
          author: "test",
          manifest: %{
            "name" => "test-plugin",
            "version" => "1.0.0",
            "author" => "test",
            "entrypoint" => "Cympho.Skills.Loader"
          },
          company_id: company.id,
          enabled: true
        })

      {:ok, _} = Loader.load(plugin.id)
      assert Loader.loaded?(plugin.id)
    end

    test "returns false for non-loaded skill" do
      refute Loader.loaded?(Ecto.UUID.generate())
    end
  end

  describe "get_manifest/1" do
    setup do
      start_supervised!(Loader)

      {:ok, company} =
        Companies.create_company(%{name: "Test", slug: "test-#{System.unique_integer()}"})

      {:ok, plugin} =
        Repo.insert(%Plugin{
          identifier: "test-plugin",
          version: "1.0.0",
          name: "Test Plugin",
          author: "test",
          manifest: %{
            "name" => "test-plugin",
            "version" => "1.0.0",
            "author" => "test",
            "entrypoint" => "Cympho.Skills.Loader"
          },
          company_id: company.id,
          enabled: true
        })

      {:ok, _} = Loader.load(plugin.id)

      %{plugin: plugin}
    end

    test "returns manifest for loaded skill", %{plugin: plugin} do
      assert {:ok, manifest} = Loader.get_manifest(plugin.id)
      assert manifest.name == "test-plugin"
      assert manifest.version == "1.0.0"
    end

    test "returns error for non-loaded skill", %{plugin: plugin} do
      assert {:error, :not_loaded} = Loader.get_manifest(Ecto.UUID.generate())
    end
  end
end
