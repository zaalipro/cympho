# Cympho Plugin SDK

## Overview

The Cympho Plugin System allows you to extend the Cympho platform with custom functionality. Plugins run as isolated GenServer processes and can interact with the host system through capability-gated services.

## Plugin Structure

A plugin consists of:

1. **Manifest** - Metadata and capability declarations
2. **Plugin Module** - A GenServer that implements `Cympho.Plugins.Worker`
3. **Optional Dependencies** - Tools, UI contributions, scheduled jobs

## Manifest Format

```json
{
  "identifier": "my-plugin",
  "name": "My Plugin",
  "version": "1.0.0",
  "description": "A sample plugin",
  "author": "Your Name",
  "capabilities": [
    "read:issues",
    "write:issues",
    "read:agents",
    "expose:tools"
  ]
}
```

## Available Capabilities

- **`read:issues`** - Read issues and comments
- **`write:issues`** - Create and update issues
- **`read:agents`** - List and view agents
- **`write:agents`** - Modify agents
- **`read:companies`** - Read company data
- **`write:companies`** - Modify company settings
- **`read:projects`** - Read project data
- **`write:projects`** - Modify projects
- **`schedule:jobs`** - Create scheduled jobs
- **`expose:tools`** - Expose tools to agents
- **`expose:ui`** - Add UI elements
- **`webhooks`** - Register webhooks

## Creating a Plugin

### 1. Define Your Plugin Module

```elixir
defmodule MyPlugin do
  use Cympho.Plugins.Worker

  @impl true
  def handle_init(state) do
    # Called when plugin starts
    {:ok, state}
  end

  @impl true
  def handle_info({:process_issue, issue_id}, state) do
    # Handle custom messages
    {:noreply, state}
  end
end
```

### 2. Interact with Host Services

```elixir
defmodule MyPlugin do
  use Cympho.Plugins.Worker
  alias Cympho.Plugins.HostServices

  @impl true
  def handle_init(state) do
    # Log a message
    HostServices.log(
      state.plugin.id,
      state.company_id,
      "info",
      "Plugin initialized"
    )

    # Read an issue (requires "read:issues")
    case HostServices.get_issue(issue_id, state.plugin.capabilities) do
      {:ok, issue} ->
        # Process issue
        {:ok, state}

      {:error, :unauthorized} ->
        HostServices.log(state.plugin.id, state.company_id, "error", "Unauthorized")
        {:stop, :unauthorized}
    end
  end
end
```

### 3. Expose Tools

```elixir
@impl true
def handle_init(state) do
  tool_definition = %{
    "name" => "my_tool",
    "description" => "Does something useful",
    "parameters" => %{
      "input" => %{"type" => "string", "description" => "Input data"}
    },
    "function" => "my_plugin_tool",
    "company_id" => state.company_id
  }

  case HostServices.expose_tool(state.plugin.id, tool_definition, state.plugin.capabilities) do
    :ok -> {:ok, state}
    {:error, :unauthorized} -> {:stop, :unauthorized}
  end
end
```

### 4. Register UI Contributions

```elixir
@impl true
def handle_init(state) do
  contribution = %{
    "type" => "menu_item",
    "location" => "issue_sidebar",
    "label" => "My Plugin",
    "icon" => "plugin-icon",
    "path" => "/plugins/my-plugin",
    "company_id" => state.company_id
  }

  case HostServices.register_ui_contribution(state.plugin.id, contribution, state.plugin.capabilities) do
    :ok -> {:ok, state}
    {:error, :unauthorized} -> {:stop, :unauthorized}
  end
end
```

### 5. Schedule Jobs

```elixir
@impl true
def handle_init(state) do
  # Schedule a job to run every hour
  case HostServices.schedule_job(
    state.plugin.id,
    state.company_id,
    "hourly_task",
    "0 * * * *",
    &MyPlugin.hourly_task/1,
    state.plugin.capabilities
  ) do
    {:ok, _routine} -> {:ok, state}
    {:error, :unauthorized} -> {:stop, :unauthorized}
  end
end
```

## Plugin State Management

Store and retrieve plugin state:

```elixir
# Save state
Cympho.Plugins.set_plugin_state(
  plugin_id,
  company_id,
  "my_key",
  %{data: "value"}
)

# Retrieve state
case Cympho.Plugins.get_plugin_state_value(plugin_id, "my_key") do
  {:ok, value} -> # Use value
  {:error, :not_found} -> # Handle missing state
end
```

## Plugin Settings

Access plugin settings:

```elixir
# Get a setting
api_key = Cympho.Plugins.HostServices.get_setting(plugin, "api_key")

# Update a setting
Cympho.Plugins.HostServices.set_setting(plugin, "api_key", "new_value")
```

## Lifecycle Hooks

- **`handle_init/1`** - Called when plugin starts
- **`handle_info/2`** - Handle async messages
- **`handle_call/3`** - Handle synchronous requests
- **`handle_cast/2`** - Handle async casts
- **`handle_terminate/2`** - Cleanup on shutdown

## Error Handling

```elixir
@impl true
def handle_info({:process_issue, issue_id}, state) do
  case HostServices.get_issue(issue_id, state.plugin.capabilities) do
    {:ok, issue} ->
      # Process issue
      {:noreply, state}

    {:error, :unauthorized} ->
      HostServices.log(state.plugin.id, state.company_id, "error", "Access denied")
      {:noreply, state}

    {:error, reason} ->
      HostServices.log(state.plugin.id, state.company_id, "error", "Error: #{inspect(reason)}")
      {:stop, reason, state}
  end
end
```

## Best Practices

1. **Minimal Capabilities** - Only request capabilities you need
2. **Error Logging** - Log all errors for debugging
3. **Graceful Degradation** - Handle unauthorized access gracefully
4. **State Management** - Use plugin state for persistence
5. **Resource Cleanup** - Clean up resources in `handle_terminate/2`

## Example Plugin

See `lib/cympho/plugins/example/` for a complete example plugin demonstrating all features.

## API Reference

### Cympho.Plugins.HostServices

- `get_issue(issue_id, capabilities)` - Get an issue
- `list_issues(company_id, filters, capabilities)` - List issues
- `create_issue(company_id, attrs, capabilities)` - Create an issue
- `update_issue(issue, attrs, capabilities)` - Update an issue
- `list_agents(company_id, capabilities)` - List agents
- `get_agent(agent_id, capabilities)` - Get an agent
- `schedule_job(plugin_id, company_id, name, schedule, function, capabilities)` - Schedule a job
- `expose_tool(plugin_id, tool_definition, capabilities)` - Expose a tool
- `register_ui_contribution(plugin_id, contribution, capabilities)` - Register UI
- `log(plugin_id, company_id, level, message, metadata)` - Log a message
- `get_setting(plugin, key, default)` - Get a setting
- `set_setting(plugin, key, value)` - Set a setting

### Cympho.Plugins

- `list_plugins(opts)` - List plugins
- `get_plugin(id)` - Get a plugin
- `create_plugin(attrs)` - Create a plugin
- `update_plugin(plugin, attrs)` - Update a plugin
- `toggle_plugin(plugin)` - Enable/disable a plugin
- `set_plugin_state(plugin_id, company_id, key, value)` - Set state
- `get_plugin_state_value(plugin_id, key)` - Get state
- `create_plugin_log(plugin_id, company_id, level, message, metadata)` - Create log
- `validate_manifest(manifest)` - Validate a manifest

## Support

For questions or issues, please contact the Cympho team or open an issue in the repository.
