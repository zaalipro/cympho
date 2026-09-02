defmodule Cympho.Plugins.Runtime do
  @moduledoc """
  Central lifecycle boundary for persisted plugins and their runtime resources.

  The database row is the source of truth. Disabling a plugin makes that row
  inactive before its worker is stopped. Deleting a plugin also unregisters
  its dynamic MCP tools and revokes their grants. Runtime-affecting edits
  restart a running worker with the freshly persisted plugin configuration.
  """

  require Logger

  alias Cympho.Mcp.ToolRegistry
  alias Cympho.Plugins.{Catalog, ProcessRegistry, Supervisor}
  alias Cympho.Skills
  alias Cympho.Skills.Plugin

  @runtime_error %{"runtime_start" => "worker_failed_to_start"}
  @runtime_refresh_error %{"runtime_refresh" => "worker_failed_to_restart"}
  @runtime_fields [:identifier, :version, :manifest, :capabilities, :settings, :company_id]

  def install_catalog_entry(entry, company_id) when is_map(entry) and is_binary(company_id) do
    attrs = %{
      identifier: entry.identifier,
      name: entry.name,
      version: entry.version,
      description: entry.description,
      author: entry.author,
      manifest: Catalog.install_manifest(entry),
      status: "installed",
      capabilities: entry.capabilities,
      enabled: true,
      company_id: company_id
    }

    with {:ok, plugin} <- Skills.create_plugin(attrs) do
      activate_plugin(plugin, entry)
    end
  end

  def create_plugin(attrs \\ %{}) do
    Skills.create_plugin(attrs)
  end

  def activate_plugin(%Plugin{} = plugin, entry \\ nil) do
    with_plugin_lock(plugin, fn ->
      with {:ok, current_plugin} <- Skills.get_plugin(plugin.id) do
        do_activate_plugin(current_plugin, entry)
      end
    end)
  end

  defp do_activate_plugin(plugin, entry) do
    with {:ok, entry} <- resolve_entry(plugin, entry),
         true <- entry.installable? || {:error, :not_installable},
         {:ok, active_plugin} <-
           Skills.update_plugin(plugin, %{
             status: "active",
             enabled: true,
             manifest_errors: %{}
           }) do
      start_activated_plugin(active_plugin, entry)
    else
      {:error, %Ecto.Changeset{}} = error -> error
      {:error, reason} -> start_failed(plugin, reason)
    end
  end

  def start_plugin(%Plugin{} = plugin, entry \\ nil) do
    with true <- runtime_active?(plugin) || {:error, :plugin_inactive} do
      case whereis(plugin) do
        pid when is_pid(pid) ->
          {:ok, pid}

        nil ->
          with {:ok, entry} <- resolve_entry(plugin, entry),
               true <- entry.installable? || {:error, :not_installable} do
            start_plugin_module(plugin, entry.source_module)
          end
      end
    end
  end

  def stop_plugin(%Plugin{} = plugin) do
    case whereis(plugin) do
      nil -> :ok
      pid -> stop_plugin_pid(pid)
    end
  end

  @doc """
  Persists plugin edits and refreshes the runtime when configuration used by a
  running worker changed.
  """
  def update_plugin(%Plugin{} = plugin, attrs) when is_map(attrs) do
    with_plugin_lock(plugin, fn ->
      with {:ok, current_plugin} <- Skills.get_plugin(plugin.id) do
        pid = whereis(current_plugin)
        module = if is_pid(pid), do: Supervisor.plugin_module(pid)

        case Skills.update_plugin(current_plugin, attrs) do
          {:ok, updated_plugin} ->
            sync_updated_plugin(current_plugin, updated_plugin, pid, module)

          {:error, %Ecto.Changeset{}} = error ->
            error
        end
      end
    end)
  end

  def toggle_plugin(%Plugin{} = plugin) do
    with_plugin_lock(plugin, fn ->
      with {:ok, current_plugin} <- Skills.get_plugin(plugin.id) do
        if current_plugin.enabled do
          do_disable_plugin(current_plugin)
        else
          do_enable_plugin(current_plugin)
        end
      end
    end)
  end

  def disable_plugin(%Plugin{} = plugin) do
    with_plugin_lock(plugin, fn ->
      with {:ok, current_plugin} <- Skills.get_plugin(plugin.id) do
        do_disable_plugin(current_plugin)
      end
    end)
  end

  defp do_disable_plugin(plugin) do
    with {:ok, disabled_plugin} <-
           Skills.update_plugin(plugin, %{enabled: false, status: "disabled"}),
         :ok <- stop_plugin(disabled_plugin) do
      {:ok, disabled_plugin}
    end
  end

  @doc """
  Stops a plugin, unregisters all of its dynamic tools (revoking grants), then
  deletes the persisted plugin row.
  """
  def delete_plugin(%Plugin{} = plugin) do
    with_plugin_lock(plugin, fn ->
      with {:ok, current_plugin} <- Skills.get_plugin(plugin.id),
           {:ok, disabled_plugin} <- disable_for_removal(current_plugin),
           :ok <- stop_plugin(disabled_plugin),
           {:ok, _unregistered_tools} <- ToolRegistry.unregister_for_plugin(plugin.id),
           {:ok, deleted} <- Skills.delete_plugin(disabled_plugin) do
        {:ok, deleted}
      end
    end)
  end

  def uninstall_plugin(%Plugin{} = plugin) do
    delete_plugin(plugin)
  end

  def whereis(%Plugin{id: plugin_id}) when is_binary(plugin_id) do
    case Registry.lookup(ProcessRegistry, plugin_id) do
      [{pid, _value}] when is_pid(pid) -> if(Process.alive?(pid), do: pid)
      [] -> nil
    end
  end

  def restore_enabled_plugins do
    Skills.list_plugins()
    |> Enum.filter(&(&1.enabled and local_catalog_plugin?(&1)))
    |> Enum.each(&restore_plugin/1)

    :ok
  end

  defp restore_plugin(plugin) do
    with_plugin_lock(plugin, fn ->
      case Skills.get_plugin(plugin.id) do
        {:ok, %{enabled: true} = current_plugin} ->
          case do_activate_plugin(current_plugin, nil) do
            {:ok, _plugin} -> :ok
            {:error, _reason} -> :ok
          end

        _inactive_or_deleted ->
          :ok
      end
    end)
  end

  defp start_activated_plugin(plugin, entry) do
    case start_plugin(plugin, entry) do
      {:ok, _pid} -> {:ok, plugin}
      {:error, reason} -> start_failed(plugin, reason)
    end
  end

  defp start_failed(plugin, reason) do
    _ = stop_plugin(plugin)
    failed_plugin = mark_start_failed(plugin)

    Logger.error("Catalog plugin worker failed to start",
      plugin_id: plugin.id,
      company_id: plugin.company_id,
      identifier: plugin.identifier
    )

    {:error, {:runtime_start_failed, reason, failed_plugin}}
  end

  defp sync_updated_plugin(previous, updated, pid, module) do
    cond do
      not runtime_active?(updated) ->
        with :ok <- stop_plugin(updated), do: {:ok, updated}

      is_pid(pid) and runtime_changed?(previous, updated) ->
        restart_plugin(updated, pid, module)

      is_nil(pid) and local_catalog_plugin?(updated) ->
        start_refreshed_plugin(updated)

      true ->
        {:ok, updated}
    end
  end

  defp restart_plugin(plugin, pid, module) do
    with :ok <- stop_plugin_pid(pid),
         {:ok, source_module} <- resolve_source_module(plugin, module),
         {:ok, _pid} <- start_plugin_module(plugin, source_module) do
      {:ok, plugin}
    else
      {:error, reason} -> refresh_failed(plugin, reason)
    end
  end

  defp refresh_failed(plugin, reason) do
    failed_plugin = mark_refresh_failed(plugin)

    Logger.error("Plugin worker failed to refresh",
      plugin_id: plugin.id,
      company_id: plugin.company_id,
      identifier: plugin.identifier
    )

    {:error, {:runtime_refresh_failed, reason, failed_plugin}}
  end

  defp start_refreshed_plugin(plugin) do
    case start_plugin(plugin) do
      {:ok, _pid} -> {:ok, plugin}
      {:error, reason} -> refresh_failed(plugin, reason)
    end
  end

  defp resolve_source_module(_plugin, module) when is_atom(module), do: {:ok, module}

  defp resolve_source_module(plugin, nil) do
    with {:ok, entry} <- resolve_entry(plugin, nil),
         true <- entry.installable? || {:error, :not_installable} do
      {:ok, entry.source_module}
    end
  end

  defp start_plugin_module(plugin, module) do
    case Supervisor.start_plugin(module, plugin: plugin, company_id: plugin.company_id) do
      {:error, {:already_started, pid}} -> {:ok, pid}
      result -> result
    end
  end

  defp stop_plugin_pid(pid) do
    case Supervisor.stop_plugin(pid) do
      :ok ->
        :ok

      {:error, :not_found} ->
        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        else
          :ok
        end
    end
  catch
    :exit, {:noproc, _call} -> :ok
  end

  defp disable_for_removal(%Plugin{enabled: false, status: "disabled"} = plugin),
    do: {:ok, plugin}

  defp disable_for_removal(plugin) do
    Skills.update_plugin(plugin, %{enabled: false, status: "disabled"})
  end

  defp do_enable_plugin(plugin) do
    if local_catalog_plugin?(plugin) do
      do_activate_plugin(plugin, nil)
    else
      Skills.update_plugin(plugin, %{enabled: true, status: "active"})
    end
  end

  defp with_plugin_lock(%Plugin{id: plugin_id}, fun)
       when is_binary(plugin_id) and is_function(fun, 0) do
    :global.trans({{__MODULE__, plugin_id}, self()}, fun)
  end

  defp runtime_active?(%Plugin{enabled: true, status: "active"}), do: true
  defp runtime_active?(_plugin), do: false

  defp runtime_changed?(previous, updated) do
    Enum.any?(@runtime_fields, &(Map.get(previous, &1) != Map.get(updated, &1)))
  end

  defp resolve_entry(%Plugin{identifier: identifier}, nil), do: Catalog.fetch(identifier)

  defp resolve_entry(%Plugin{identifier: identifier}, %{identifier: identifier} = entry),
    do: {:ok, entry}

  defp resolve_entry(%Plugin{}, _entry), do: {:error, :catalog_entry_mismatch}

  defp local_catalog_plugin?(%Plugin{manifest: %{"source" => "local_catalog"}}), do: true
  defp local_catalog_plugin?(_plugin), do: false

  defp mark_start_failed(plugin) do
    case Skills.update_plugin(plugin, %{
           status: "error",
           enabled: false,
           manifest_errors: @runtime_error
         }) do
      {:ok, failed_plugin} -> failed_plugin
      {:error, _changeset} -> plugin
    end
  end

  defp mark_refresh_failed(plugin) do
    case Skills.update_plugin(plugin, %{
           status: "error",
           enabled: false,
           manifest_errors: @runtime_refresh_error
         }) do
      {:ok, failed_plugin} -> failed_plugin
      {:error, _changeset} -> plugin
    end
  end
end
