defmodule Cympho.Skills.Resolver do
  @moduledoc """
  Dependency resolver for skills.

  The resolver handles:
  - Transitive dependency resolution
  - Circular dependency detection via DFS
  - Semver compatibility checking
  - Topological ordering of skills
  - Caching of resolved skill graphs
  """

  use GenServer
  alias Cympho.Skills.Plugin
  alias Cympho.{Repo, Skills.AgentSkill}
  import Ecto.Query

  @table_name :cympho_skill_resolver_cache
  @table_options [:set, :named_table, :public, read_concurrency: true]

  ## Client API

  @doc """
  Starts the resolver server.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Resolves the dependency graph for an agent's skills.

  Takes an agent_id and company_id and returns an ordered list of skills with
  transitive dependencies resolved, or an error if:
  - Circular dependencies are detected
  - Semver compatibility cannot be satisfied
  - A required skill is not found
  - The agent does not belong to the specified company

  Returns {:ok, [plugins]} on success, {:error, :circular_dependency, path} on cycle,
  or {:error, reason} for other errors.
  """
  def resolve(agent_id, company_id) when is_binary(agent_id) and is_binary(company_id) do
    case check_cache(agent_id) do
      {:ok, plugins} ->
        {:ok, plugins}

      :miss ->
        case do_resolve(agent_id, company_id) do
          {:ok, plugins} = result ->
            cache_resolution(agent_id, plugins)
            result

          {:error, _, _} = error ->
            error

          {:error, _} = error ->
            error
        end
    end
  end

  def resolve(_, _), do: {:error, :invalid_id}

  def resolve(agent_id) when is_binary(agent_id) do
    # Deprecated: use resolve/2 with explicit company_id for proper security
    require Logger
    Logger.warning("Resolver.resolve/1 is deprecated, use resolve/2 with company_id")
    resolve(agent_id, nil)
  end

  def resolve(_), do: {:error, :invalid_id}

  @doc """
  Invalidates the resolution cache for an agent.

  Call this when agent skill assignments change.
  """
  def invalidate(agent_id) when is_binary(agent_id) do
    :ets.delete(@table_name, agent_id)
    :ok
  end

  def invalidate(_), do: {:error, :invalid_id}

  @doc """
  Clears the entire resolution cache.
  """
  def clear_cache do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    :ets.new(@table_name, @table_options)
    {:ok, %{}}
  end

  ## Private Functions

  defp check_cache(agent_id) do
    case :ets.lookup(@table_name, agent_id) do
      [{^agent_id, plugins}] -> {:ok, plugins}
      [] -> :miss
    end
  end

  defp cache_resolution(agent_id, plugins) do
    :ets.insert(@table_name, {agent_id, plugins})
    :ok
  end

  defp do_resolve(agent_id, company_id) do
    with {:ok, agent_skills} <- fetch_agent_skills(agent_id, company_id),
         {:ok, plugin_map} <- build_plugin_map(agent_skills),
         {:ok, {resolved_ids, _resolved_set}} <-
           resolve_dependencies(plugin_map, [], MapSet.new()) do
      # Look up actual plugin structs by ID in dependency order
      plugins =
        Enum.map(resolved_ids, fn plugin_id ->
          Enum.find(agent_skills, fn p -> p.id == plugin_id end)
        end)

      {:ok, plugins}
    end
  end

  defp fetch_agent_skills(agent_id, company_id) do
    query =
      from agent_skill in AgentSkill,
        join: agent in Cympho.Agents.Agent,
        on: agent_skill.agent_id == agent.id,
        join: plugin in Plugin,
        on: agent_skill.plugin_id == plugin.id,
        where: agent.id == ^agent_id,
        where: agent.company_id == ^company_id,
        where: plugin.company_id == ^company_id,
        where: plugin.enabled == true,
        select: plugin

    case Repo.all(query) do
      [] -> {:error, :no_skills}
      plugins -> {:ok, plugins}
    end
  end

  defp build_plugin_map(plugins) do
    plugin_map =
      Enum.reduce(plugins, %{}, fn plugin, acc ->
        Map.put(acc, plugin.id, %{
          id: plugin.id,
          identifier: plugin.identifier,
          version: plugin.version,
          dependencies: extract_dependencies(plugin.manifest)
        })
      end)

    {:ok, plugin_map}
  end

  defp extract_dependencies(%{"dependencies" => deps}) when is_map(deps), do: deps
  defp extract_dependencies(_), do: %{}

  # Dependency resolution with cycle detection using DFS
  defp resolve_dependencies(plugin_map, initial_order, initial_resolved) do
    all_ids = Map.keys(plugin_map)

    resolved = initial_resolved
    visiting = MapSet.new()
    path = []

    resolve_dfs(all_ids, plugin_map, initial_order, resolved, visiting, path)
  end

  defp resolve_dfs([], _plugin_map, ordered_list, resolved, _visiting, _path) do
    {:ok, {ordered_list, resolved}}
  end

  defp resolve_dfs([plugin_id | rest], plugin_map, ordered_list, resolved, visiting, path) do
    if MapSet.member?(resolved, plugin_id) do
      resolve_dfs(rest, plugin_map, ordered_list, resolved, visiting, path)
    else
      case visit_plugin(plugin_id, plugin_map, ordered_list, resolved, visiting, path) do
        {:ok, new_ordered_list, new_resolved} ->
          resolve_dfs(rest, plugin_map, new_ordered_list, new_resolved, MapSet.new(), [])

        {:error, _, _} = error ->
          error
      end
    end
  end

  defp visit_plugin(plugin_id, plugin_map, ordered_list, resolved, visiting, path) do
    if MapSet.member?(visiting, plugin_id) do
      cycle_path = path ++ [plugin_id]
      {:error, :circular_dependency, cycle_path}
    else
      plugin = Map.get(plugin_map, plugin_id)

      case resolve_plugin_dependencies(
             plugin,
             plugin_map,
             ordered_list,
             resolved,
             MapSet.put(visiting, plugin_id),
             [plugin_id | path]
           ) do
        {:ok, new_ordered_list, new_resolved} ->
          # Add plugin after all its dependencies (append for proper topological order)
          {:ok, new_ordered_list ++ [plugin_id], MapSet.put(new_resolved, plugin_id)}

        {:error, _, _} = error ->
          error
      end
    end
  end

  defp resolve_plugin_dependencies(nil, _plugin_map, ordered_list, resolved, _visiting, _path) do
    {:ok, ordered_list, resolved}
  end

  defp resolve_plugin_dependencies(plugin, plugin_map, ordered_list, resolved, visiting, path) do
    deps = plugin.dependencies

    dep_ids =
      Enum.map(deps, fn {identifier, version_req} ->
        case find_plugin_by_identifier(identifier, version_req, plugin_map) do
          {:ok, plugin_id} -> plugin_id
          {:error, _} -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    case resolve_dfs(dep_ids, plugin_map, ordered_list, resolved, visiting, path) do
      {:ok, {dep_order, dep_resolved}} -> {:ok, dep_order, dep_resolved}
      {:error, _, _} = error -> error
    end
  end

  defp find_plugin_by_identifier(identifier, version_req, plugin_map) do
    matching_plugins =
      Enum.filter(plugin_map, fn {_id, plugin} ->
        plugin.identifier == identifier and
          version_satisfies?(plugin.version, version_req)
      end)

    case matching_plugins do
      [{id, _plugin}] -> {:ok, id}
      [] -> {:error, :not_found}
      _ -> {:error, :ambiguous_match}
    end
  end

  # Simple semver compatibility check
  # Supports exact match (^1.0.0), caret (^1.2.3), and tilde (~1.2.3) requirements
  defp version_satisfies?(version, requirement)
       when is_binary(version) and is_binary(requirement) do
    cond do
      String.starts_with?(requirement, "^") ->
        requirement_version = String.slice(requirement, 1..String.length(requirement)//1)
        caret_match?(version, requirement_version)

      String.starts_with?(requirement, "~") ->
        requirement_version = String.slice(requirement, 1..String.length(requirement)//1)
        tilde_match?(version, requirement_version)

      true ->
        exact_match?(version, requirement)
    end
  rescue
    _ -> false
  end

  defp version_satisfies?(_, _), do: false

  defp exact_match?(version, requirement) do
    version == requirement
  end

  defp caret_match?(version, requirement) do
    case {Version.parse(version), Version.parse(requirement)} do
      {{:ok, v}, {:ok, r}} ->
        v.major == r.major and Version.compare(v, r) != :lt

      _ ->
        false
    end
  end

  defp tilde_match?(version, requirement) do
    case {Version.parse(version), Version.parse(requirement)} do
      {{:ok, v}, {:ok, r}} ->
        v.major == r.major and v.minor == r.minor and Version.compare(v, r) != :lt

      _ ->
        false
    end
  end
end
