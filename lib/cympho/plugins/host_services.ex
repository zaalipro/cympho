defmodule Cympho.Plugins.HostServices do
  @moduledoc """
  Capability-gated host services that plugins can use to interact with the host system.
  """
  require Logger

  @doc """
  Reads an issue by ID.
  Requires "read:issues" capability.
  """
  def get_issue(issue_id, capabilities) when is_list(capabilities) do
    if "read:issues" in capabilities do
      alias Cympho.Issues
      Issues.get_issue(issue_id)
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
      alias Cympho.Issues
      Issues.list_issues(company_id, filters)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Creates an issue.
  Requires "write:issues" capability.
  """
  def create_issue(company_id, attrs, capabilities) when is_list(capabilities) do
    if "write:issues" in capabilities do
      alias Cympho.Issues
      Issues.create_issue(company_id, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Updates an issue.
  Requires "write:issues" capability.
  """
  def update_issue(issue, attrs, capabilities) when is_list(capabilities) do
    if "write:issues" in capabilities do
      alias Cympho.Issues
      Issues.update_issue(issue, attrs)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Lists agents for a company.
  Requires "read:agents" capability.
  """
  def list_agents(company_id, capabilities) when is_list(capabilities) do
    if "read:agents" in capabilities do
      alias Cympho.Agents
      Agents.list_agents(company_id)
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Gets an agent by ID.
  Requires "read:agents" capability.
  """
  def get_agent(agent_id, capabilities) when is_list(capabilities) do
    if "read:agents" in capabilities do
      alias Cympho.Agents
      Agents.get_agent(agent_id)
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
             RoutineTriggers.create_trigger(routine.id, %{
               type: "cron",
               config: %{expression: schedule},
               enabled: true
             }) do
        {:ok, routine}
      end
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Exposes a tool that agents can use.
  Requires "expose:tools" capability.
  """
  def expose_tool(plugin_id, tool_definition, capabilities) when is_list(capabilities) do
    if "expose:tools" in capabilities do
      alias Cympho.Plugins

      tool_attrs = %{
        plugin_id: plugin_id,
        name: tool_definition["name"],
        description: tool_definition["description"],
        parameters: tool_definition["parameters"] || %{},
        function: tool_definition["function"]
      }

      Plugins.set_plugin_state(
        plugin_id,
        tool_definition["company_id"],
        "tool:#{tool_definition["name"]}",
        tool_attrs
      )
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Registers a UI contribution (menu item, page, widget, etc.).
  Requires "expose:ui" capability.
  """
  def register_ui_contribution(plugin_id, contribution, capabilities) when is_list(capabilities) do
    if "expose:ui" in capabilities do
      alias Cympho.Plugins

      contribution_attrs = %{
        type: contribution["type"],
        location: contribution["location"],
        label: contribution["label"],
        icon: contribution["icon"],
        path: contribution["path"],
        component: contribution["component"],
        props: contribution["props"] || %{}
      }

      Plugins.set_plugin_state(
        plugin_id,
        contribution["company_id"],
        "ui_contribution:#{contribution["type"]}:#{contribution["location"]}",
        contribution_attrs
      )
    else
      {:error, :unauthorized}
    end
  end

  @doc """
  Logs a message from the plugin.
  """
  def log(plugin_id, company_id, level, message, metadata \\ %{}) do
    alias Cympho.Plugins
    Plugins.create_plugin_log(plugin_id, company_id, level, message, metadata)

    level_atom =
      case level do
        "debug" -> :debug
        "info" -> :info
        "warn" -> :warning
        "error" -> :error
        _ -> :info
      end

    Logger.log(level_atom, "[Plugin #{plugin_id}] #{message}")
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
    alias Cympho.Plugins
    settings = Map.put(plugin.settings || %{}, key, value)
    Plugins.update_plugin(plugin, %{settings: settings})
  end
end
