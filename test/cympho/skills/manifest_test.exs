defmodule Cympho.Skills.ManifestTest do
  use Cympho.DataCase
  alias Cympho.Skills.Manifest

  describe "validate/1" do
    test "validates a valid manifest" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "capabilities" => ["read", "write"],
        "dependencies" => %{"other-skill" => "^1.0.0"},
        "entrypoint" => "Cympho.Skills.TestSkill",
        "permissions" => ["skill:read"]
      }

      assert {:ok, %Manifest{name: "test-skill", version: "1.0.0"}} = Manifest.validate(manifest)
    end

    test "requires name field" do
      manifest = %{
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill"
      }

      assert {:error, ["name is required" | _]} = Manifest.validate(manifest)
    end

    test "requires version field" do
      manifest = %{
        "name" => "test-skill",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill"
      }

      assert {:error, ["version is required" | _]} = Manifest.validate(manifest)
    end

    test "requires author field" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "entrypoint" => "Cympho.Skills.TestSkill"
      }

      assert {:error, ["author is required" | _]} = Manifest.validate(manifest)
    end

    test "requires entrypoint field" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author"
      }

      assert {:error, ["entrypoint is required" | _]} = Manifest.validate(manifest)
    end

    test "validates semver version" do
      manifest = %{
        "name" => "test-skill",
        "version" => "invalid",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill"
      }

      assert {:error, ["version must be a valid semver string" | _]} = Manifest.validate(manifest)
    end

    test "accepts valid semver versions" do
      valid_versions = ["1.0.0", "2.1.3", "0.0.1", "10.20.30"]

      Enum.each(valid_versions, fn version ->
        manifest = %{
          "name" => "test-skill",
          "version" => version,
          "author" => "test-author",
          "entrypoint" => "Cympho.Skills.TestSkill"
        }

        assert {:ok, %Manifest{version: ^version}} = Manifest.validate(manifest)
      end)
    end

    test "validates capabilities is a list" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill",
        "capabilities" => "not-a-list"
      }

      assert {:error, ["capabilities must be a list" | _]} = Manifest.validate(manifest)
    end

    test "validates dependencies is a map" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill",
        "dependencies" => "not-a-map"
      }

      assert {:error, ["dependencies must be a map" | _]} = Manifest.validate(manifest)
    end

    test "validates permissions is a list" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill",
        "permissions" => "not-a-list"
      }

      assert {:error, ["permissions must be a list" | _]} = Manifest.validate(manifest)
    end

    test "uses default values for optional fields" do
      manifest = %{
        "name" => "test-skill",
        "version" => "1.0.0",
        "author" => "test-author",
        "entrypoint" => "Cympho.Skills.TestSkill"
      }

      assert {:ok, %Manifest{capabilities: [], dependencies: %{}, permissions: []}} =
               Manifest.validate(manifest)
    end
  end
end
