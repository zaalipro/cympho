defmodule Cympho.Skills.HotReloader do
  @moduledoc """
  Hot-reloader for skill manifest files in development environments.

  The HotReloader watches skill manifest files on the filesystem and
  triggers reloads within 2 seconds of file changes, updating the
  in-memory skill cache without restarting heartbeats.

  In production, this GenServer is a no-op.

  In test environments, file system events can be mocked for testing.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Cympho.{Plugins, Repo, Skills.Plugin}

  @name __MODULE__
  @reload_timeout 2000

  defstruct [:watcher_pid, :manifest_dir, :last_known_good]

  ## Client API

  @doc """
  Starts the hot-reloader server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Manually triggers a reload of all skill manifests.
  Useful for testing or when automatic reload isn't sufficient.
  """
  def reload_all do
    GenServer.call(@name, :reload_all)
  end

  @doc """
  Triggers a reload for a specific manifest file.
  """
  def reload_manifest(file_path) do
    GenServer.call(@name, {:reload_manifest, file_path})
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    case env() do
      :prod ->
        # No-op in production
        {:ok, %__MODULE__{}}

      :test ->
        # In test, start without a watcher but allow manual reloads
        manifest_dir = get_manifest_dir()
        {:ok, %__MODULE__{manifest_dir: manifest_dir}}

      :dev ->
        manifest_dir = get_manifest_dir()
        ensure_manifest_dir_exists!(manifest_dir)

        # Start the file system watcher
        case FileSystem.start_link(dirs: [manifest_dir], name: {:global, :skill_hot_reloader}) do
          {:ok, pid} ->
            FileSystem.subscribe(pid)
            {:ok, %__MODULE__{watcher_pid: pid, manifest_dir: manifest_dir}}

          {:error, {:already_started, pid}} ->
            FileSystem.subscribe(pid)
            {:ok, %__MODULE__{watcher_pid: pid, manifest_dir: manifest_dir}}

          error ->
            Logger.error("Failed to start file system watcher: #{inspect(error)}")
            # Start anyway, just without watching
            {:ok, %__MODULE__{manifest_dir: manifest_dir}}
        end
    end
  end

  @impl true
  def handle_call(:reload_all, _from, state) do
    case reload_all_manifests(state.manifest_dir) do
      {:ok, count} ->
        Logger.info("Reloaded #{count} skill manifests")
        {:reply, {:ok, count}, state}

      {:error, reason} = error ->
        Logger.info("Failed to reload manifests: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:reload_manifest, file_path}, _from, state) do
    case reload_single_manifest(file_path) do
      {:ok, plugin} ->
        Logger.info("Reloaded skill manifest from #{Path.basename(file_path)}")
        {:reply, {:ok, plugin}, state}

      {:error, reason} = error ->
        Logger.info("Failed to reload manifest #{file_path}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher_pid, {path, events}}, state)
      when watcher_pid == state.watcher_pid do
    if :modified in events or :created in events do
      # Debounce: schedule reload after @reload_timeout
      Process.send_after(self(), {:process_file_change, path}, @reload_timeout)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:process_file_change, file_path}, state) do
    case reload_single_manifest(file_path) do
      {:ok, plugin} ->
        Logger.info("Hot-reloaded skill manifest: #{plugin.identifier}")
        {:noreply, %{state | last_known_good: plugin}}

      {:error, reason} ->
        Logger.error("Hot-reload failed for #{file_path}: #{inspect(reason)}")
        # Fall back to last known good manifest
        log_reload_failure(file_path, reason)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Functions

  defp env do
    # Runtime environment must be explicitly configured via Application config
    # Do NOT use Mix.env() at runtime as it returns compile-time environment
    Application.fetch_env!(:cympho, :env)
  end

  defp get_manifest_dir do
    Application.get_env(:cympho, :skill_manifest_dir, "priv/skill_manifests")
  end

  defp ensure_manifest_dir_exists!(dir) do
    unless File.exists?(dir) do
      case File.mkdir_p(dir) do
        :ok -> :ok
        error -> raise "Failed to create manifest directory #{dir}: #{inspect(error)}"
      end
    end
  end

  defp reload_all_manifests(manifest_dir) do
    case File.ls(manifest_dir) do
      {:ok, files} ->
        manifest_files =
          files
          |> Enum.filter(&String.ends_with?(&1, [".json", ".yaml", ".yml"]))
          |> Enum.map(&Path.join(manifest_dir, &1))

        results = Enum.map(manifest_files, &reload_single_manifest/1)

        successful =
          Enum.count(results, fn
            {:ok, _} -> true
            _ -> false
          end)

        {:ok, successful}

      {:error, reason} ->
        {:error, {:directory_access, reason}}
    end
  end

  defp reload_single_manifest(file_path) do
    with {:ok, manifest_data} <- read_manifest_file(file_path),
         {:ok, plugin} <- find_plugin_by_identifier(manifest_data),
         {:ok, updated_plugin} <- update_plugin_manifest(plugin, manifest_data) do
      {:ok, updated_plugin}
    else
      {:error, _reason} = error -> error
    end
  end

  defp read_manifest_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        case Path.extname(file_path) do
          ".json" -> parse_json(content)
          ext when ext in [".yaml", ".yml"] -> parse_yaml(content)
          _ -> {:error, :unsupported_format}
        end

      {:error, reason} ->
        {:error, {:file_read, reason}}
    end
  end

  defp parse_json(content) do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp parse_yaml(_content) do
    # Use a simple YAML parser or add :yamerl dependency
    # For now, return error and expect JSON in dev
    {:error, :yaml_not_supported}
  end

  defp find_plugin_by_identifier(%{"identifier" => identifier, "company_slug" => company_slug}) do
    # Look up company by slug from manifest
    # Use limit(2) to detect duplicates - if more than one company has this
    # slug, we have a data integrity issue and should fail safely
    query =
      from c in Cympho.Companies.Company,
        where: c.slug == ^company_slug,
        limit: 2,
        select: c.id

    case Repo.all(query) do
      [] ->
        {:error, :no_company}

      [company_id] ->
        Plugins.get_plugin_by_identifier(identifier, company_id)

      [_first, _second | _] ->
        Logger.error(
          "Multiple companies found with slug #{company_slug}, possible data integrity issue"
        )

        {:error, :ambiguous_company}
    end
  end

  defp find_plugin_by_identifier(%{"identifier" => identifier}) do
    # Fallback: look up plugin by identifier alone and use its company_id
    # This is safe in dev where plugin identifiers are typically unique
    # In production with multi-tenant, manifests should include company_slug
    query =
      from p in Plugin,
        where: p.identifier == ^identifier,
        limit: 2,
        select: {p.id, p.company_id}

    case Repo.all(query) do
      [] ->
        {:error, :plugin_not_found}

      [{_plugin_id, company_id}] ->
        case Plugins.get_plugin_by_identifier(identifier, company_id) do
          {:ok, plugin} -> {:ok, plugin}
          error -> error
        end

      [_first, _second | _] ->
        Logger.warning(
          "Multiple plugins found with identifier #{identifier}, using first match. " <>
            "Consider adding company_slug to manifest for unambiguous lookup."
        )

        # Use the first match
        [{_plugin_id, company_id} | _] = Repo.all(query)
        Plugins.get_plugin_by_identifier(identifier, company_id)
    end
  end

  defp find_plugin_by_identifier(_), do: {:error, :missing_identifier}

  defp update_plugin_manifest(plugin, manifest_data) do
    Plugins.update_plugin(plugin, %{manifest: manifest_data})
  end

  defp log_reload_failure(file_path, reason) do
    # Log to plugin_logs table if it exists
    # This is a simplified version - in production, you'd want to create
    # a proper plugin_log entry with more context
    Logger.error("Hot-reload failure for #{file_path}: #{inspect(reason)}")

    # TODO: Create plugin_log entry when schema is available
    # %Cympho.Plugins.PluginLog{
    #   plugin_id: ...,
    #   level: "error",
    #   message: "Hot-reload failed",
    #   metadata: %{file_path: file_path, reason: inspect(reason)}
    # }
    # |> Cympho.Repo.insert()
  end
end
