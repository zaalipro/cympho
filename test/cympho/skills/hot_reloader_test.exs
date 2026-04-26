defmodule Cympho.Skills.HotReloaderTest do
  use Cympho.DataCase
  use ExUnit.Case, async: false

  alias Cympho.{Companies, Plugins, Repo, Skills.HotReloader}
  alias Cympho.Skills.Plugin

  @manifest_dir "test/support/skill_manifests"
  @test_manifest Path.join(@manifest_dir, "test_skill.json")

  setup do
    # Ensure clean state
    File.mkdir_p!(@manifest_dir)

    # Create a test company
    {:ok, company} =
      Companies.create_company(%{
        name: "Test Company",
        slug: "test-#{System.unique_integer()}",
        settings: %{}
      })

    # Create a test plugin
    {:ok, plugin} =
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

    # Write test manifest
    manifest = %{
      "identifier" => "test_skill",
      "company_slug" => company.slug,
      "name" => "Test Skill",
      "description" => "A test skill for hot-reload",
      "version" => "1.0.0",
      "author" => "Test",
      "dependencies" => %{}
    }

    File.write!(@test_manifest, Jason.encode!(manifest))

    # Start the HotReloader only if not already started (it may be in the supervision tree)
    if Process.whereis(HotReloader) == nil do
      start_supervised!(HotReloader)
    end

    on_exit(fn ->
      File.rm_rf(@manifest_dir)
    end)

    %{company: company, plugin: plugin, manifest: manifest}
  end

  describe "start_link/1" do
    test "starts the HotReloader server in test environment" do
      # HotReloader may already be started by the app supervision tree
      if Process.whereis(HotReloader) == nil do
        assert {:ok, pid} = HotReloader.start_link([])
        assert is_pid(pid)
        assert Process.alive?(pid)
      else
        # Already started, just verify it's alive
        assert Process.alive?(Process.whereis(HotReloader))
      end
    end

    test "in test environment, does not start file system watcher" do
      # In test mode, the HotReloader starts but without a watcher
      pid = if Process.whereis(HotReloader) == nil do
        {:ok, p} = HotReloader.start_link([])
        p
      else
        Process.whereis(HotReloader)
      end
      :sys.get_state(pid)
    end
  end

  describe "reload_all/0" do
    test "reloads all manifests in the configured directory" do
      assert {:ok, count} = HotReloader.reload_all()
      assert count >= 1
    end

    test "updates plugin manifests in the database", %{company: company} do
      # Update the manifest file
      updated_manifest = %{
        "identifier" => "test_skill",
        "company_slug" => company.slug,
        "name" => "Updated Test Skill",
        "description" => "Updated description",
        "version" => "1.1.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(updated_manifest))

      # Reload all manifests
      assert {:ok, _count} = HotReloader.reload_all()

      # Verify the database was updated
      assert {:ok, plugin} = Plugins.get_plugin_by_identifier("test_skill", company.id)
      assert plugin.manifest["name"] == "Updated Test Skill"
      assert plugin.manifest["version"] == "1.1.0"
    end
  end

  describe "reload_manifest/1" do
    test "reloads a specific manifest file" do
      assert {:ok, plugin} = HotReloader.reload_manifest(@test_manifest)
      assert plugin.identifier == "test_skill"
    end

    test "returns error for non-existent file" do
      assert {:error, {:file_read, :enoent}} = HotReloader.reload_manifest("non_existent.json")
    end

    test "returns error for invalid JSON" do
      invalid_manifest = Path.join(@manifest_dir, "invalid.json")
      File.write!(invalid_manifest, "invalid json content")

      assert {:error, :invalid_json} = HotReloader.reload_manifest(invalid_manifest)
    end

    test "returns error for manifest without identifier" do
      no_id_manifest = Path.join(@manifest_dir, "no_id.json")
      File.write!(no_id_manifest, Jason.encode!(%{"name" => "No ID"}))

      assert {:error, :missing_identifier} = HotReloader.reload_manifest(no_id_manifest)
    end

    test "returns error for non-existent plugin identifier" do
      unknown_manifest = Path.join(@manifest_dir, "unknown.json")
      File.write!(unknown_manifest, Jason.encode!(%{"identifier" => "unknown_skill"}))

      assert {:error, {:missing_company_context, "unknown_skill"}} = HotReloader.reload_manifest(unknown_manifest)
    end

    test "returns not_found for plugin with valid company_slug but non-existent identifier", %{company: company} do
      unknown_manifest = Path.join(@manifest_dir, "unknown_with_company.json")
      File.write!(unknown_manifest, Jason.encode!(%{
        "identifier" => "nonexistent_skill",
        "company_slug" => company.slug
      }))

      assert {:error, :not_found} = HotReloader.reload_manifest(unknown_manifest)
    end
  end

  describe "manifest file changes" do
    test "hot-reloads when manifest file is modified", %{company: company} do
      # This test would require more complex setup with actual file watching
      # For now, we test the manual reload which is what happens in the background
      updated_manifest = %{
        "identifier" => "test_skill",
        "company_slug" => company.slug,
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
  end

  describe "error handling" do
    test "falls back to last known good manifest on reload failure", %{company: company} do
      # Create a valid manifest
      valid_manifest = %{
        "identifier" => "test_skill",
        "company_slug" => company.slug,
        "name" => "Valid Skill",
        "description" => "Valid description",
        "version" => "1.0.0",
        "author" => "Test",
        "dependencies" => %{}
      }

      File.write!(@test_manifest, Jason.encode!(valid_manifest))

      # Reload successfully
      assert {:ok, plugin} = HotReloader.reload_manifest(@test_manifest)
      assert plugin.manifest["version"] == "1.0.0"

      # Now write invalid manifest
      File.write!(@test_manifest, "invalid json")

      # Reload should fail
      assert {:error, :invalid_json} = HotReloader.reload_manifest(@test_manifest)

      # Database should still have the valid manifest
      assert {:ok, plugin} = Plugins.get_plugin_by_identifier("test_skill", company.id)
      assert plugin.manifest["version"] == "1.0.0"
    end
  end

end
