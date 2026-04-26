defmodule Cympho.Skills.HotReloaderTest do
  use Cympho.DataCase
  use ExUnit.Case, async: false

  alias Cympho.{Companies, Plugins, Skills.HotReloader}
  alias Cympho.Skills.Plugin

  @manifest_dir "test/support/skill_manifests"
  @test_manifest Path.join(@manifest_dir, "test_skill.json")

  describe "reload operations" do
    setup do
      File.mkdir_p!(@manifest_dir)

      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company-#{System.unique_integer()}",
          settings: %{}
        })

      {:ok, _plugin} =
        Plugins.create_plugin(%{
          identifier: "test_skill",
          name: "Test Skill",
          description: "A test skill",
          version: "1.0.0",
          author: "Test",
          manifest: %{},
          enabled: true,
          company_id: company.id
        })

      manifest = %{
        "identifier" => "test_skill",
        "name" => "Test Skill",
        "description" => "A test skill for hot-reload",
        "version" => "1.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(manifest))

      on_exit(fn ->
        File.rm_rf(@manifest_dir)
      end)

      %{company: company}
    end

    test "reload_all reloads all manifests" do
      assert {:ok, count} = HotReloader.reload_all()
      assert count >= 1
    end

    test "reload_all updates plugin manifests in the database", %{company: company} do
      updated_manifest = %{
        "identifier" => "test_skill",
        "name" => "Updated Test Skill",
        "description" => "Updated description",
        "version" => "1.1.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(updated_manifest))

      assert {:ok, _count} = HotReloader.reload_all()

      assert {:ok, plugin} = Plugins.get_plugin_by_identifier("test_skill", company.id)
      assert plugin.manifest["name"] == "Updated Test Skill"
      assert plugin.manifest["version"] == "1.1.0"
    end

    test "reload_manifest reloads a specific manifest file" do
      assert {:ok, plugin} = HotReloader.reload_manifest(@test_manifest)
      assert plugin.identifier == "test_skill"
    end

    test "reload_manifest returns error for non-existent file" do
      assert {:error, {:file_read, _}} = HotReloader.reload_manifest("non_existent.json")
    end

    test "reload_manifest returns error for invalid JSON" do
      invalid_manifest = Path.join(@manifest_dir, "invalid.json")
      File.write!(invalid_manifest, "invalid json content")

      assert {:error, :invalid_json} = HotReloader.reload_manifest(invalid_manifest)
    end

    test "reload_manifest returns error for manifest without identifier" do
      no_id_manifest = Path.join(@manifest_dir, "no_id.json")
      File.write!(no_id_manifest, Jason.encode!(%{"name" => "No ID"}))

      assert {:error, :missing_identifier} = HotReloader.reload_manifest(no_id_manifest)
    end

    test "hot-reloads when manifest file is modified" do
      updated_manifest = %{
        "identifier" => "test_skill",
        "name" => "Hot Reloaded Skill",
        "description" => "This was hot-reloaded",
        "version" => "2.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(updated_manifest))

      assert {:ok, plugin} = HotReloader.reload_manifest(@test_manifest)
      assert plugin.manifest["name"] == "Hot Reloaded Skill"
      assert plugin.manifest["version"] == "2.0.0"
    end

    test "falls back to last known good manifest on reload failure", %{company: company} do
      valid_manifest = %{
        "identifier" => "test_skill",
        "name" => "Valid Skill",
        "description" => "Valid description",
        "version" => "1.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(valid_manifest))

      assert {:ok, plugin} = HotReloader.reload_manifest(@test_manifest)
      assert plugin.manifest["version"] == "1.0.0"

      File.write!(@test_manifest, "invalid json")

      assert {:error, :invalid_json} = HotReloader.reload_manifest(@test_manifest)

      assert {:ok, plugin} = Plugins.get_plugin_by_identifier("test_skill", company.id)
      assert plugin.manifest["version"] == "1.0.0"
    end
  end

  describe "multi-tenant company_slug resolution" do
    setup do
      File.mkdir_p!(@manifest_dir)

      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company-#{System.unique_integer()}",
          settings: %{}
        })

      {:ok, _plugin} =
        Plugins.create_plugin(%{
          identifier: "test_skill",
          name: "Test Skill",
          description: "A test skill",
          version: "1.0.0",
          author: "Test",
          manifest: %{},
          enabled: true,
          company_id: company.id
        })

      on_exit(fn ->
        File.rm_rf(@manifest_dir)
      end)

      %{company: company}
    end

    test "resolves plugin using company_slug from manifest", %{company: company} do
      manifest = %{
        "identifier" => "test_skill",
        "company_slug" => company.slug,
        "name" => "Slug-Resolved Skill",
        "version" => "2.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      slug_manifest = Path.join(@manifest_dir, "slug_test.json")
      File.write!(slug_manifest, Jason.encode!(manifest))

      assert {:ok, plugin} = HotReloader.reload_manifest(slug_manifest)
      assert plugin.identifier == "test_skill"
      assert plugin.manifest["name"] == "Slug-Resolved Skill"

      File.rm(slug_manifest)
    end

    test "returns no_company error for unknown company_slug" do
      manifest = %{
        "identifier" => "test_skill",
        "company_slug" => "nonexistent-company-slug-#{System.unique_integer()}",
        "name" => "Orphan Skill",
        "version" => "1.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      orphan_manifest = Path.join(@manifest_dir, "orphan_test.json")
      File.write!(orphan_manifest, Jason.encode!(manifest))

      assert {:error, :no_company} = HotReloader.reload_manifest(orphan_manifest)

      File.rm(orphan_manifest)
    end

    test "slug unique constraint prevents ambiguous company lookups" do
      # The companies table has a unique constraint on slug,
      # so the ambiguous_company code path is unreachable in normal operation.
      # This test verifies the constraint exists by confirming duplicate slugs are rejected.
      slug = "unique-test-slug-#{System.unique_integer()}"

      {:ok, _c1} = Companies.create_company(%{name: "Co 1", slug: slug})
      {:error, changeset} = Companies.create_company(%{name: "Co 2", slug: slug})

      assert %{slug: ["has already been taken"]} = errors_on(changeset)
    end

    test "falls back to plugin lookup when company_slug is absent", %{company: company} do
      manifest = %{
        "identifier" => "test_skill",
        "name" => "Fallback Resolved Skill",
        "version" => "1.5.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      fallback_manifest = Path.join(@manifest_dir, "fallback_test.json")
      File.write!(fallback_manifest, Jason.encode!(manifest))

      assert {:ok, plugin} = HotReloader.reload_manifest(fallback_manifest)
      assert plugin.identifier == "test_skill"
      assert plugin.company_id == company.id

      File.rm(fallback_manifest)
    end
  end
end
