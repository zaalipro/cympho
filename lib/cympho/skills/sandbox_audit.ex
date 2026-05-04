defmodule Cympho.Skills.Sandbox.Audit do
  @moduledoc """
  Audit logging for skill authorization decisions.
  """
  alias Cympho.{Agents.Agent, Plugins.PluginLog, Repo}
  alias Cympho.Skills.Plugin
  import Ecto.Query

  def log_decision(agent_id, agent_role, capability, result) do
    plugin_id = get_audit_plugin_id()

    log_entry = %{
      level: log_level_from_result(result),
      message: format_message(agent_role, capability, result),
      metadata: build_metadata(agent_id, agent_role, capability, result),
      timestamp: DateTime.utc_now(),
      plugin_id: plugin_id,
      company_id: get_company_id_for_agent(agent_id)
    }

    %PluginLog{} |> PluginLog.changeset(log_entry) |> Repo.insert()
    :ok
  end

  defp get_audit_plugin_id do
    query =
      from p in Plugin,
        where: p.identifier == "system.sandbox" or p.identifier == "cympho.core",
        limit: 1

    case Repo.one(query) do
      nil -> nil
      plugin -> plugin.id
    end
  end

  defp get_company_id_for_agent(nil), do: nil

  defp get_company_id_for_agent(agent_id) do
    case Repo.get(Agent, agent_id) do
      nil -> nil
      agent -> agent.company_id
    end
  end

  defp log_level_from_result(:ok), do: "info"
  defp log_level_from_result({:error, :unauthorized, _}), do: "warn"

  defp format_message(nil, capability, result) do
    case result do
      :ok -> "Authorization granted for '#{capability}'"
      {:error, :unauthorized, reason} -> "Authorization denied for '#{capability}': #{reason}"
    end
  end

  defp format_message(agent_role, capability, result) do
    role_str = if agent_role, do: ":#{agent_role}", else: "unknown"
    "#{format_message(nil, capability, result)} (role: #{role_str})"
  end

  defp build_metadata(agent_id, agent_role, capability, result) do
    %{
      "agent_id" => agent_id,
      "agent_role" => if(is_atom(agent_role), do: Atom.to_string(agent_role), else: agent_role),
      "capability" => capability,
      "result" => result_to_string(result),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp result_to_string(:ok), do: "granted"
  defp result_to_string({:error, :unauthorized, reason}), do: "denied: #{reason}"

  def logs_for_agent(agent_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      from pl in PluginLog,
        where: fragment("?->>'agent_id' = ?", pl.metadata, ^agent_id),
        order_by: [desc: pl.timestamp],
        limit: ^limit

    Repo.all(query)
  end

  def logs_for_capability(capability, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    query =
      from pl in PluginLog,
        where: fragment("?->>'capability' = ?", pl.metadata, ^capability),
        order_by: [desc: pl.timestamp],
        limit: ^limit

    Repo.all(query)
  end

  def denied_attempts(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    agent_id = Keyword.get(opts, :agent_id)
    capability = Keyword.get(opts, :capability)

    query =
      from pl in PluginLog,
        where: fragment("?->>'result' LIKE ?", pl.metadata, "denied%"),
        order_by: [desc: pl.timestamp],
        limit: ^limit

    query =
      if agent_id,
        do: where(query, [pl], fragment("?->>'agent_id' = ?", pl.metadata, ^agent_id)),
        else: query

    query =
      if capability,
        do: where(query, [pl], fragment("?->>'capability' = ?", pl.metadata, ^capability)),
        else: query

    Repo.all(query)
  end
end
