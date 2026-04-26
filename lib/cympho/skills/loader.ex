defmodule Cympho.Skills.Loader do
  @moduledoc """
  Skill loader for activating and deactivating skills at runtime.

  The loader manages skill lifecycle:
  - Validates skill manifests against the schema
  - Loads skills into the runtime (ensures code is available)
  - Unloads skills from the runtime
  """

  use GenServer
  alias Cympho.Skills.{Manifest, Plugin}
  alias Cympho.Repo

  @table_name :cympho_skill_loader_cache
  @table_options [:set, :named_table, :public, read_concurrency: true]

  ## Client API

  @doc """
  Starts the loader server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Validates a JSON manifest against the schema.

  Returns {:ok, manifest} if valid, {:error, reasons} if invalid.
  """
  def validate_manifest(manifest_data) when is_map(manifest_data) do
    Manifest.validate(manifest_data)
  end

  def validate_manifest(_), do: {:error, ["manifest must be a map"]}

  @doc """
  Loads and activates a skill for runtime use.

  Takes a plugin ID and:
  1. Validates the manifest
  2. Ensures the entrypoint module exists
  3. Caches the loaded skill
  4. Returns the loaded manifest

  Returns {:ok, manifest} if successful, {:error, reason} if not.
  """
  def load(plugin_id) when is_binary(plugin_id) do
    case Repo.get(Plugin, plugin_id) do
      nil -> {:error, :not_found}
      plugin -> load_plugin(plugin)
    end
  end

  def load(_), do: {:error, :invalid_id}

  @doc """
  Unloads a skill from runtime use.

  Removes the skill from the cache and marks it as inactive.

  Returns :ok if successful, {:error, reason} if not.
  """
  def unload(plugin_id) when is_binary(plugin_id) do
    GenServer.call(__MODULE__, {:unload, plugin_id})
  end

  def unload(_), do: {:error, :invalid_id}

  @doc """
  Checks if a skill is currently loaded.

  Returns true if loaded, false otherwise.
  """
  def loaded?(plugin_id) when is_binary(plugin_id) do
    case :ets.lookup(@table_name, plugin_id) do
      [{^plugin_id, _manifest}] -> true
      [] -> false
    end
  end

  @doc """
  Gets the manifest for a loaded skill.

  Returns {:ok, manifest} if loaded, {:error, :not_loaded} if not.
  """
  def get_manifest(plugin_id) when is_binary(plugin_id) do
    case :ets.lookup(@table_name, plugin_id) do
      [{^plugin_id, manifest}] -> {:ok, manifest}
      [] -> {:error, :not_loaded}
    end
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, @table_options)
    {:ok, %{}}
  end

  @impl true
  def handle_call({:unload, plugin_id}, _from, state) do
    result =
      case :ets.lookup(@table_name, plugin_id) do
        [{^plugin_id, _manifest}] ->
          :ets.delete(@table_name, plugin_id)
          :ok
        [] ->
          :ok
      end

    {:reply, result, state}
  end

  ## Private Functions

  defp load_plugin(plugin) do
    with {:ok, manifest} <- validate_manifest(plugin.manifest),
         :ok <- validate_entrypoint(manifest.entrypoint),
         :ok <- cache_skill(plugin.id, manifest) do
      {:ok, manifest}
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_entrypoint(entrypoint) when is_binary(entrypoint) do
    module_name = String.to_existing_atom("Elixir." <> entrypoint)

    case Code.ensure_loaded(module_name) do
      {:module, _} -> :ok
      {:error, _} -> {:error, {:entrypoint_not_found, entrypoint}}
    end
  rescue
    ArgumentError -> {:error, {:entrypoint_not_found, entrypoint}}
  end

  defp cache_skill(plugin_id, manifest) do
    :ets.insert(@table_name, {plugin_id, manifest})
    :ok
  end
end
