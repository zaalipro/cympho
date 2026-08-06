defmodule Cympho.Plugins.HostServices do
  @moduledoc """
  Capability-gated host services that plugins can use to interact with the host system.
  """
  require Logger

  @doc """
  Reads an issue by ID.
  Requires "read:issues" capability.
  """
  def get_issue(company_id, issue_id, capabilities) when is_list(capabilities) do
    if "read:issues" in capabilities do
      Cympho.Issues.get_company_issue(company_id, issue_id)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists issues for a company.
  Requires "read:issues" capability.
  """
  def list_issues(company_id, filters, capabilities) when is_list(capabilities) do
    if "read:issues" in capabilities do
      Cympho.Issues.list_issues(Map.put(filters, :company_id, company_id))
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Creates an issue.
  Requires "write:issues" capability.
  """
  def create_issue(company_id, attrs, capabilities)
      when is_binary(company_id) and is_map(attrs) and is_list(capabilities) do
    if "write:issues" in capabilities do
      alias Cympho.Issues

      with {:ok, scoped_attrs} <- scope_issue_attrs(attrs, company_id) do
        Issues.create_issue(scoped_attrs)
      end
    else
      {:error, :unauthorized}
    end
  end

  def create_issue(_company_id, _attrs, capabilities) when is_list(capabilities) do
    if "write:issues" in capabilities,
      do: {:error, :invalid_company_scope},
      else: {:error, :unauthorized}
  end

  @doc """
  Updates an issue within a company scope.

  Requires `"write:issues"` capability. Loads the issue via
  `Issues.get_company_issue/2` (fail-closed on foreign or missing rows) and
  strips any caller-supplied `company_id` so plugins cannot re-tenant an issue.
  """
  def update_issue(company_id, issue_id, attrs, capabilities)
      when is_binary(company_id) and is_binary(issue_id) and is_map(attrs) and
             is_list(capabilities) do
    if "write:issues" in capabilities do
      alias Cympho.Issues

      with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id) do
        Issues.update_issue(issue, strip_company_id(attrs))
      end
    else
      {:error, :unauthorized}
    end
  end

  def update_issue(_company_id, _issue_id, _attrs, capabilities) when is_list(capabilities) do
    if "write:issues" in capabilities,
      do: {:error, :invalid_company_scope},
      else: {:error, :unauthorized}
  end

  @doc """
  Lists agents for a company.
  Requires "read:agents" capability.
  """
  def list_agents(company_id, capabilities) when is_list(capabilities) do
    if "read:agents" in capabilities do
      alias Cympho.Agents
      Agents.list_agents_by_company(company_id)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Gets an agent by ID.
  Requires "read:agents" capability.
  """
  def get_agent(company_id, agent_id, capabilities) when is_list(capabilities) do
    if "read:agents" in capabilities do
      Cympho.Agents.get_company_agent(company_id, agent_id)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Schedules a job to run at a specific time or interval.
  Requires "schedule:jobs" capability.
  """
  def schedule_job(plugin_id, company_id, job_name, schedule, _function, capabilities)
      when is_list(capabilities) do
    if "schedule:jobs" in capabilities do
      alias Cympho.Routines
      alias Cympho.RoutineTriggers

      job_attrs = %{
        name: job_name,
        description: "Scheduled job from plugin #{plugin_id}",
        company_id: company_id,
        trigger_type: "cron",
        trigger_config: %{
          expression: schedule
        },
        enabled: true
      }

      with {:ok, routine} <- Routines.create_routine(job_attrs),
           {:ok, _trigger} <-
             RoutineTriggers.create_schedule_trigger(%{
               "routine_id" => routine.id,
               "cron_expression" => schedule,
               "enabled" => true
             }) do
        {:ok, routine}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Exposes a tool that agents can use via the governed MCP tool registry.

  Requires `"expose:tools"` capability. Registration is company-scoped and
  fail-closed: `company_id` must be supplied as the second argument (preferred)
  or present on the tool definition. Dynamic tools remain hidden from MCP
  until an explicit `Cympho.Mcp.ToolGrants` allow grant is issued.
  """
  def expose_tool(plugin_id, company_id, tool_definition, capabilities)
      when is_binary(company_id) and is_map(tool_definition) and is_list(capabilities) do
    if "expose:tools" in capabilities do
      do_expose_tool(plugin_id, company_id, tool_definition)
    else
      {:error, :unauthorized}
    end
  end

  def expose_tool(plugin_id, tool_definition, capabilities)
      when is_map(tool_definition) and is_list(capabilities) do
    company_id =
      Map.get(tool_definition, "company_id") || Map.get(tool_definition, :company_id)

    cond do
      "expose:tools" not in capabilities ->
        {:error, :unauthorized}

      not is_binary(company_id) or company_id == "" ->
        # Resolve company from the installed plugin when definition omits it.
        case resolve_plugin_company(plugin_id) do
          {:ok, resolved_company_id} ->
            do_expose_tool(plugin_id, resolved_company_id, tool_definition)

          {:error, _} = err ->
            err
        end

      true ->
        do_expose_tool(plugin_id, company_id, tool_definition)
    end
  end

  def expose_tool(_plugin_id, _tool_definition, capabilities) when is_list(capabilities) do
    if "expose:tools" in capabilities,
      do: {:error, :invalid_tool_definition},
      else: {:error, :unauthorized}
  end

  defp do_expose_tool(plugin_id, company_id, tool_definition) do
    alias Cympho.Mcp.ToolRegistry

    definition =
      tool_definition
      |> Map.drop(["company_id", :company_id])
      |> Map.put("plugin_id", plugin_id)

    case ToolRegistry.register(company_id, definition) do
      {:ok, tool} ->
        Logger.info(
          "[Plugin #{plugin_id}] exposing tool: #{tool.name}",
          company_id: company_id,
          plugin_id: plugin_id,
          tool_name: tool.name
        )

        {:ok,
         %{
           id: tool.id,
           name: tool.name,
           description: tool.description,
           input_schema: tool.input_schema,
           company_id: tool.company_id,
           plugin_id: tool.plugin_id,
           status: tool.status
         }}

      {:error, reason} ->
        Logger.warning(
          "[Plugin #{plugin_id}] failed to expose tool",
          company_id: company_id,
          plugin_id: plugin_id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp resolve_plugin_company(plugin_id) when is_binary(plugin_id) do
    case Cympho.Skills.get_plugin(plugin_id) do
      {:ok, %{company_id: company_id}} when is_binary(company_id) and company_id != "" ->
        {:ok, company_id}

      {:ok, _} ->
        {:error, :invalid_company_scope}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_plugin_company(_), do: {:error, :invalid_company_scope}

  @doc """
  Registers a UI contribution (menu item, page, widget, etc.).
  Requires "expose:ui" capability.
  """
  def register_ui_contribution(plugin_id, contribution, capabilities)
      when is_list(capabilities) do
    if "expose:ui" in capabilities do
      Logger.info(
        "[Plugin #{plugin_id}] registering UI: #{contribution["type"]} at #{contribution["location"]}"
      )

      {:ok, contribution}
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Logs a message from the plugin.
  """
  def log(plugin_id, company_id, level, message, _metadata \\ %{}) do
    level_atom =
      case level do
        "debug" -> :debug
        "info" -> :info
        "warn" -> :warning
        "error" -> :error
        _ -> :info
      end

    Logger.log(level_atom, "[Plugin #{plugin_id}] [company: #{company_id}] #{message}")
  end

  @doc """
  Gets a setting value for the plugin.
  """
  def get_setting(plugin, key, default \\ nil) do
    Map.get(plugin.settings || %{}, key, default)
  end

  @doc """
  Sets a setting value for the plugin.
  """
  def set_setting(plugin, key, value) do
    alias Cympho.Skills
    settings = Map.put(plugin.settings || %{}, key, value)
    Skills.update_plugin(plugin, %{settings: settings})
  end

  defp scope_issue_attrs(attrs, company_id) do
    attrs = strip_company_id(attrs)
    keys = Map.keys(attrs)

    cond do
      Enum.all?(keys, &is_atom/1) -> {:ok, Map.put(attrs, :company_id, company_id)}
      Enum.all?(keys, &is_binary/1) -> {:ok, Map.put(attrs, "company_id", company_id)}
      true -> {:error, :invalid_attributes}
    end
  end

  defp strip_company_id(attrs) when is_map(attrs) do
    Map.drop(attrs, [:company_id, "company_id"])
  end
end
