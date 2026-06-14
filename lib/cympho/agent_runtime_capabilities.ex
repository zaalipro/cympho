defmodule Cympho.AgentRuntimeCapabilities do
  @moduledoc """
  Shared runtime capability checks for dispatch, preflight, and action safety.
  """

  @repo_delivery_adapters ~w(claude_code codex cursor openclaw)
  @repo_delivery_process_presets ~w(claude_code codex cursor openclaw)
  @repo_delivery_process_commands ~w(claude codex cursor cursor-agent openclaw)
  @agrenting_repo_token_keys ~w(AGRENTING_REPO_ACCESS_TOKEN GITHUB_TOKEN)

  @doc """
  Returns true when an agent runtime can plausibly produce repo artifacts.

  A generic `process` adapter is not enough by itself: custom commands such as
  `echo` are useful for smoke tests, but they cannot edit files, run tests, or
  create PR evidence. Process runtimes must use a known coding preset/command
  or opt in explicitly with `repo_capable: true`.
  """
  def repo_delivery_capable?(agent_or_adapter, opts \\ [])

  def repo_delivery_capable?(%{} = agent, opts) do
    case adapter_name(map_value(agent, :adapter)) do
      "process" -> process_repo_delivery_capable?(agent)
      "agrenting" -> agrenting_repo_delivery_capable?(agent, opts)
      adapter -> adapter in @repo_delivery_adapters
    end
  end

  def repo_delivery_capable?(adapter, _opts) do
    adapter_name(adapter) in @repo_delivery_adapters
  end

  defp process_repo_delivery_capable?(agent) do
    explicit_repo_capable?(agent) or
      process_preset(agent) in @repo_delivery_process_presets or
      process_command(agent) in @repo_delivery_process_commands
  end

  defp explicit_repo_capable?(agent) do
    [
      nested_value(agent, :runtime_config, "repo_capable"),
      nested_value(agent, :runtime_config, "repo_delivery_capable"),
      nested_value(agent, :config, "repo_capable"),
      nested_value(agent, :config, "repo_delivery_capable")
    ]
    |> Enum.any?(&truthy?/1)
  end

  defp agrenting_repo_delivery_capable?(agent, opts) do
    explicit_repo_capable?(agent) or
      (delivery_mode(agent) == "push" and repo_push_token_present?(agent, opts))
  end

  defp delivery_mode(agent) do
    mode =
      nested_value(agent, :runtime_config, "delivery_mode") ||
        nested_value(agent, :config, "delivery_mode") ||
        "output"

    normalize_token(mode)
  end

  defp repo_push_token_present?(agent, opts) do
    configured? =
      [
        nested_value(agent, :runtime_config, "repo_access_token"),
        nested_value(agent, :config, "repo_access_token"),
        nested_env_value(agent, :runtime_config, "AGRENTING_REPO_ACCESS_TOKEN"),
        nested_env_value(agent, :runtime_config, "GITHUB_TOKEN"),
        nested_env_value(agent, :config, "AGRENTING_REPO_ACCESS_TOKEN"),
        nested_env_value(agent, :config, "GITHUB_TOKEN")
      ]
      |> Enum.any?(&present?/1)

    configured? or repo_token_secret_present?(agent, opts)
  end

  defp repo_token_secret_present?(agent, opts) do
    opts
    |> repo_secret_keys(agent)
    |> Enum.any?(&(&1 in @agrenting_repo_token_keys))
  end

  defp process_preset(agent) do
    preset =
      nested_value(agent, :runtime_config, "process_preset") ||
        nested_value(agent, :config, "process_preset") ||
        nested_value(agent, :runtime_config, "preset") ||
        nested_value(agent, :config, "preset")

    normalize_token(preset)
  end

  defp process_command(agent) do
    command =
      nested_value(agent, :runtime_config, "command") ||
        nested_value(agent, :config, "command")

    command
    |> to_string()
    |> String.trim()
    |> Path.basename()
    |> normalize_token()
  end

  defp truthy?(value) when value in [true, 1], do: true

  defp truthy?(value) when is_binary(value) do
    value |> normalize_token() |> then(&(&1 in ~w(1 true yes y repo repo_delivery)))
  end

  defp truthy?(_value), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp repo_secret_keys(opts, agent) do
    case Keyword.fetch(opts, :secret_keys) do
      {:ok, keys} when is_list(keys) ->
        Enum.filter(keys, &is_binary/1)

      _ ->
        if Keyword.get(opts, :load_secret_keys?, false) do
          load_secret_keys(agent)
        else
          []
        end
    end
  end

  defp load_secret_keys(agent) do
    case map_value(agent, :id) do
      id when is_binary(id) and id != "" ->
        id
        |> Cympho.Secrets.list_secrets_for_agent()
        |> Enum.map(& &1.key)

      _ ->
        []
    end
  rescue
    _ -> []
  end

  defp nested_value(agent, field, key) do
    case map_value(agent, field) do
      %{} = map -> Map.get(map, key) || Map.get(map, String.to_atom(key))
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp nested_env_value(agent, field, key) do
    case nested_value(agent, field, "env") do
      %{} = env -> Map.get(env, key) || Map.get(env, String.to_atom(key))
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp adapter_name(adapter), do: normalize_token(adapter)

  defp normalize_token(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end
end
