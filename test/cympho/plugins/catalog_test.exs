defmodule Cympho.Plugins.CatalogTest do
  use Cympho.DataCase

  defmodule FailingPlugin do
    use Cympho.Plugins.Worker

    def handle_init(state) do
      if Map.get(state, :allow_start?), do: {:ok, state}, else: {:error, :cannot_start}
    end
  end

  alias Cympho.Companies
  alias Cympho.Mcp.{ToolGrants, ToolRegistry}
  alias Cympho.Plugins.Catalog
  alias Cympho.Plugins.ExamplePlugin
  alias Cympho.Plugins.Runtime
  alias Cympho.Plugins.Supervisor, as: PluginSupervisor
  alias Cympho.Skills
  alias Cympho.Skills.Manifest

  test "catalog entries are unique, validated, and backed by loaded local modules" do
    entries = Catalog.entries()
    identifiers = Enum.map(entries, & &1.identifier)

    assert entries != []
    assert Enum.uniq(identifiers) == identifiers

    Enum.each(entries, fn entry ->
      assert {:ok, ^entry} = Catalog.validate_entry(entry)
      assert Code.ensure_loaded?(entry.source_module)
      assert {:ok, _manifest} = Manifest.validate(Catalog.install_manifest(entry))

      if entry.installable? do
        assert function_exported?(entry.source_module, :start_link, 1)
      end

      refute Map.has_key?(entry, :rating)
      refute Map.has_key?(entry, :downloads)
      refute Map.has_key?(entry, :documentation_url)
    end)
  end

  test "validation rejects malformed or unbacked catalog entries" do
    valid = hd(Catalog.entries())

    assert {:error, :invalid_identifier} =
             Catalog.validate_entry(%{valid | identifier: "Not Valid"})

    assert {:error, :invalid_version} =
             Catalog.validate_entry(%{valid | version: "latest"})

    assert {:error, :invalid_capabilities} =
             Catalog.validate_entry(%{valid | capabilities: []})

    assert {:error, :invalid_installability} =
             Catalog.validate_entry(%{valid | installable?: "yes"})

    assert {:error, :source_module_not_found} =
             Catalog.validate_entry(%{valid | source_module: Cympho.Plugins.NotARealPlugin})

    assert {:error, :source_module_not_startable} =
             Catalog.validate_entry(%{
               valid
               | installable?: true,
                 source_module: CymphoWeb.GithubController
             })
  end

  test "the installable local entry starts through the plugin supervisor" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Runtime", slug: unique_slug()})

    {:ok, plugin} =
      Skills.create_plugin(%{
        identifier: entry.identifier,
        name: entry.name,
        version: entry.version,
        description: entry.description,
        author: entry.author,
        manifest: Catalog.install_manifest(entry),
        capabilities: entry.capabilities,
        company_id: company.id
      })

    assert entry.source_module == ExamplePlugin

    assert {:ok, pid} =
             PluginSupervisor.start_plugin(entry.source_module,
               plugin: plugin,
               company_id: company.id
             )

    assert {:ok, :running} = GenServer.call(pid, :get_status)
    assert :ok = PluginSupervisor.stop_plugin(pid)
  end

  test "runtime restore is idempotent for enabled catalog plugins" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Restore", slug: unique_slug()})

    {:ok, plugin} =
      Skills.create_plugin(%{
        identifier: entry.identifier,
        name: entry.name,
        version: entry.version,
        description: entry.description,
        author: entry.author,
        manifest: Catalog.install_manifest(entry),
        capabilities: entry.capabilities,
        status: "installed",
        enabled: true,
        company_id: company.id
      })

    assert :ok = Runtime.restore_enabled_plugins()
    first_pid = Runtime.whereis(plugin)
    assert is_pid(first_pid)

    assert :ok = Runtime.restore_enabled_plugins()
    assert Runtime.whereis(plugin) == first_pid
    assert {:ok, restored} = Skills.get_plugin(plugin.id)
    assert restored.status == "active"
    assert :ok = Runtime.stop_plugin(plugin)
  end

  test "runtime restore leaves non-catalog plugin records untouched" do
    {:ok, company} = Companies.create_company(%{name: "Custom Plugin", slug: unique_slug()})

    {:ok, plugin} =
      Skills.create_plugin(%{
        identifier: "custom-plugin",
        name: "Custom Plugin",
        version: "1.0.0",
        manifest: %{"source" => "uploaded"},
        capabilities: ["read:issues"],
        status: "installed",
        enabled: true,
        company_id: company.id
      })

    assert :ok = Runtime.restore_enabled_plugins()
    assert {:ok, unchanged} = Skills.get_plugin(plugin.id)
    assert unchanged.status == "installed"
    assert unchanged.enabled == true
    assert unchanged.manifest_errors == %{}
  end

  test "disabling a catalog plugin stops its supervised worker" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Disable", slug: unique_slug()})
    {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)
    pid = Runtime.whereis(plugin)

    assert is_pid(pid)
    assert {:ok, disabled} = Runtime.disable_plugin(plugin)
    assert disabled.enabled == false
    assert disabled.status == "disabled"
    refute Process.alive?(pid)
    assert Runtime.whereis(disabled) == nil
  end

  test "runtime start failure leaves a visible disabled error record" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Failure", slug: unique_slug()})

    failing_entry = %{
      entry
      | identifier: "failing-plugin",
        name: "Failing Plugin",
        source_module: FailingPlugin
    }

    {:ok, plugin} =
      Skills.create_plugin(%{
        identifier: failing_entry.identifier,
        name: failing_entry.name,
        version: failing_entry.version,
        manifest: Catalog.install_manifest(failing_entry),
        capabilities: failing_entry.capabilities,
        company_id: company.id
      })

    assert {:error, {:runtime_start_failed, _reason, failed}} =
             Runtime.activate_plugin(plugin, failing_entry)

    assert failed.status == "error"
    assert failed.enabled == false
    assert failed.manifest_errors == %{"runtime_start" => "worker_failed_to_start"}
    assert Runtime.whereis(failed) == nil
  end

  test "deleting a plugin stops its worker, unregisters tools, and revokes grants" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Delete", slug: unique_slug()})
    {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)
    pid = Runtime.whereis(plugin)

    assert is_pid(pid)

    {:ok, tool} =
      ToolRegistry.register(company.id, %{
        "name" => "catalog_cleanup_tool",
        "plugin_id" => plugin.id
      })

    {:ok, grant} =
      ToolGrants.create_grant(%{
        company_id: company.id,
        tool_id: tool.id,
        tool_name: tool.name,
        status: "allow"
      })

    assert {:ok, deleted} = Runtime.delete_plugin(plugin)
    assert deleted.id == plugin.id
    refute Process.alive?(pid)
    assert {:error, :not_found} = Skills.get_plugin(plugin.id)
    assert {:error, :not_found} = ToolRegistry.get_active(company.id, tool.name)
    assert Repo.get!(Cympho.Mcp.RegisteredTool, tool.id).status == "unregistered"
    assert Repo.get!(Cympho.Mcp.ToolGrant, grant.id).status == "revoked"
  end

  test "runtime configuration edits restart a worker with fresh settings and capabilities" do
    entry = Enum.find(Catalog.entries(), & &1.installable?)
    {:ok, company} = Companies.create_company(%{name: "Catalog Refresh", slug: unique_slug()})
    {:ok, plugin} = Runtime.install_catalog_entry(entry, company.id)
    old_pid = Runtime.whereis(plugin)

    assert is_pid(old_pid)
    assert :sys.get_state(old_pid).api_key == "default-key"

    assert {:ok, updated} =
             Runtime.update_plugin(plugin, %{
               settings: %{"api_key" => "rotated-key"},
               capabilities: ["expose:tools"]
             })

    new_pid = Runtime.whereis(updated)
    state = :sys.get_state(new_pid)

    assert is_pid(new_pid)
    assert new_pid != old_pid
    refute Process.alive?(old_pid)
    assert state.api_key == "rotated-key"
    assert state.plugin.settings == %{"api_key" => "rotated-key"}
    assert state.plugin.capabilities == ["expose:tools"]

    assert {:ok, _deleted} = Runtime.delete_plugin(updated)
  end

  defp unique_slug do
    "catalog-runtime-#{System.unique_integer([:positive])}"
  end
end
