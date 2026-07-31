defmodule Cympho.Plugins.Runtime do
  @moduledoc """
  Starts and stops catalog-backed plugin workers with durable install state.

  The database row is the source of truth. The process registry prevents two
  workers for the same installed plugin, while the dynamic supervisor owns
  restart behavior.
  """

  require Logger

  alias Cympho.Plugins.{Catalog, Supervisor, ProcessRegistry}
  alias Cympho.Skills
  alias Cympho.Skills.Plugin

  @runtime_error %{"runtime_start" => "worker_failed_to_start"}

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

  def activate_plugin(%Plugin{} = plugin, entry \\ nil) do
    with {:ok, entry} <- resolve_entry(plugin, entry),
         true <- entry.installable? || {:error, :not_installable},
         {:ok, _pid} <- start_plugin(plugin, entry),
         {:ok, active_plugin} <-
           Skills.update_plugin(plugin, %{
             status: "active",
             enabled: true,
             manifest_errors: %{}
           }) do
      {:ok, active_plugin}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        _ = stop_plugin(plugin)
        {:error, changeset}

      {:error, reason} ->
        failed_plugin = mark_start_failed(plugin)

        Logger.error("Catalog plugin worker failed to start",
          plugin_id: plugin.id,
          company_id: plugin.company_id,
          identifier: plugin.identifier
        )

        {:error, {:runtime_start_failed, reason, failed_plugin}}
    end
  end

  def start_plugin(%Plugin{} = plugin, entry \\ nil) do
    case whereis(plugin) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        with {:ok, entry} <- resolve_entry(plugin, entry),
             true <- entry.installable? || {:error, :not_installable} do
          case Supervisor.start_plugin(entry.source_module,
                 plugin: plugin,
                 company_id: plugin.company_id
               ) do
            {:error, {:already_started, pid}} -> {:ok, pid}
            result -> result
          end
        end
    end
  end

  def stop_plugin(%Plugin{} = plugin) do
    case whereis(plugin) do
      nil -> :ok
      pid -> Supervisor.stop_plugin(pid)
    end
  end

  def uninstall_plugin(%Plugin{} = plugin) do
    with :ok <- stop_plugin(plugin),
         {:ok, deleted} <- Skills.delete_plugin(plugin) do
      {:ok, deleted}
    end
  end

  def whereis(%Plugin{id: plugin_id}) when is_binary(plugin_id) do
    case Registry.lookup(ProcessRegistry, plugin_id) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  def restore_enabled_plugins do
    Skills.list_plugins()
    |> Enum.filter(&(&1.enabled and local_catalog_plugin?(&1)))
    |> Enum.each(fn plugin ->
      case activate_plugin(plugin) do
        {:ok, _plugin} -> :ok
        {:error, _reason} -> :ok
      end
    end)

    :ok
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
end
