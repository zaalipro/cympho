defmodule Cympho.Plugins.ExamplePlugin do
  @moduledoc """
  Example plugin demonstrating the Cympho plugin system.
  """
  use Cympho.Plugins.Worker
  require Logger

  def handle_init(state) do
    alias Cympho.Plugins.HostServices

    # Log initialization
    HostServices.log(
      state.plugin.id,
      state.company_id,
      "info",
      "Example plugin initialized",
      %{version: state.plugin.version}
    )

    # Example: Read issues if we have the capability
    if "read:issues" in state.plugin.capabilities do
      case HostServices.list_issues(state.company_id, %{}, state.plugin.capabilities) do
        {:ok, issues} ->
          HostServices.log(
            state.plugin.id,
            state.company_id,
            "info",
            "Found #{length(issues)} issues"
          )

        {:error, reason} ->
          HostServices.log(
            state.plugin.id,
            state.company_id,
            "error",
            "Failed to list issues: #{inspect(reason)}"
          )
      end
    end

    # Example: Get a setting
    api_key = HostServices.get_setting(state.plugin, "api_key", "default-key")

    {:ok, %{state | status: :running, api_key: api_key}}
  end

  def handle_message({:process_issue, issue_id}, state) do
    alias Cympho.Plugins.HostServices

    HostServices.log(
      state.plugin.id,
      state.company_id,
      "info",
      "Processing issue #{issue_id}"
    )

    case HostServices.get_issue(state.company_id, issue_id, state.plugin.capabilities) do
      {:ok, issue} ->
        # Process the issue
        HostServices.log(
          state.plugin.id,
          state.company_id,
          "info",
          "Processed issue: #{issue.identifier}",
          %{title: issue.title}
        )

        {:noreply, state}

      {:error, :unauthorized} ->
        HostServices.log(
          state.plugin.id,
          state.company_id,
          "warn",
          "Unauthorized to access issue #{issue_id}"
        )

        {:noreply, state}

      {:error, reason} ->
        HostServices.log(
          state.plugin.id,
          state.company_id,
          "error",
          "Error processing issue: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  def handle_message(:heartbeat, state) do
    # Regular heartbeat for health checks
    {:noreply, state}
  end

  def handle_message(message, state) do
    # Log unhandled messages
    Logger.warning("Example plugin received unhandled message: #{inspect(message)}")
    {:noreply, state}
  end

  def handle_request(:get_status, _from, state) do
    {:reply, {:ok, state.status}, state}
  end

  def handle_request({:execute_task, task}, _from, state) do
    alias Cympho.Plugins.HostServices

    HostServices.log(
      state.plugin.id,
      state.company_id,
      "info",
      "Executing task: #{task}"
    )

    # Simulate task execution
    {:reply, :ok, state}
  end

  def handle_cast_request({:update_config, config}, state) do
    alias Cympho.Plugins.HostServices

    # Update plugin settings
    Enum.each(config, fn {key, value} ->
      HostServices.set_setting(state.plugin, key, value)
    end)

    {:noreply, state}
  end

  def handle_terminate(_reason, state) do
    alias Cympho.Plugins.HostServices

    HostServices.log(
      state.plugin.id,
      state.company_id,
      "info",
      "Example plugin shutting down"
    )

    :ok
  end
end
