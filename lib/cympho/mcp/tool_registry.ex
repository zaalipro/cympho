defmodule Cympho.Mcp.ToolRegistry do
  @moduledoc """
  Company-scoped registry of dynamically registered MCP tools.

  Tools are registered by plugins (via `HostServices.expose_tool/3`) and only
  become callable through MCP after an explicit `Cympho.Mcp.ToolGrants`
  authorization. Registration is fail-closed on missing `company_id`.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.GovernanceAuditLogs
  alias Cympho.Mcp.{RegisteredTool, ToolGrants}
  alias Cympho.Repo

  @doc """
  Registers (or re-activates) a dynamic tool for `company_id`.

  `definition` must include `"name"` or `:name`. Optional keys: description,
  input_schema / inputSchema, plugin_id, metadata.
  """
  @spec register(String.t(), map()) :: {:ok, RegisteredTool.t()} | {:error, term()}
  def register(company_id, definition)
      when is_binary(company_id) and company_id != "" and is_map(definition) do
    attrs = normalize_definition(definition, company_id)

    case attrs do
      {:error, _} = err ->
        err

      attrs when is_map(attrs) ->
        do_register(attrs)
    end
  end

  def register(_company_id, _definition), do: {:error, :invalid_company_scope}

  @doc """
  Unregisters a tool by id. Soft-sets status to `unregistered` and revokes
  any non-revoked grants for that tool so it disappears from MCP list/call
  immediately.
  """
  @spec unregister(String.t()) :: {:ok, RegisteredTool.t()} | {:error, term()}
  def unregister(tool_id) when is_binary(tool_id) and tool_id != "" do
    case Repo.get(RegisteredTool, tool_id) do
      nil ->
        {:error, :not_found}

      %RegisteredTool{status: "unregistered"} = tool ->
        {:ok, tool}

      %RegisteredTool{} = tool ->
        Repo.transaction(fn ->
          {:ok, unregistered} =
            tool
            |> RegisteredTool.unregister_changeset()
            |> Repo.update()

          _ =
            ToolGrants.revoke_all_for_tool(
              unregistered.company_id,
              unregistered.name,
              "tool unregistered"
            )

          GovernanceAuditLogs.log_action(
            "mcp_tool_unregistered",
            {"system", "system"},
            "Dynamic MCP tool unregistered: #{unregistered.name}",
            resource: unregistered,
            company_id: unregistered.company_id,
            metadata: %{
              tool_id: unregistered.id,
              tool_name: unregistered.name,
              plugin_id: unregistered.plugin_id
            }
          )

          unregistered
        end)
        |> case do
          {:ok, tool} -> {:ok, tool}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def unregister(_), do: {:error, :invalid_tool_id}

  @doc """
  Returns the active registered tool for `company_id` + `name`, if any.
  """
  @spec get_active(String.t(), String.t()) :: {:ok, RegisteredTool.t()} | {:error, :not_found}
  def get_active(company_id, name)
      when is_binary(company_id) and is_binary(name) and company_id != "" and name != "" do
    name = normalize_name(name)

    query =
      from t in RegisteredTool,
        where: t.company_id == ^company_id and t.name == ^name and t.status == "active"

    case Repo.one(query) do
      nil -> {:error, :not_found}
      tool -> {:ok, tool}
    end
  end

  def get_active(_, _), do: {:error, :not_found}

  @doc """
  Lists active registered tools for a company.
  """
  @spec list_registered(String.t()) :: [RegisteredTool.t()]
  def list_registered(company_id) when is_binary(company_id) and company_id != "" do
    from(t in RegisteredTool,
      where: t.company_id == ^company_id and t.status == "active",
      order_by: [asc: t.name]
    )
    |> Repo.all()
  end

  def list_registered(_), do: []

  @doc """
  Lists active tools the given agent is allowed to call (`:allow` grant).
  """
  @spec list_allowed_for_agent(String.t(), String.t()) :: [RegisteredTool.t()]
  def list_allowed_for_agent(company_id, agent_id)
      when is_binary(company_id) and is_binary(agent_id) and company_id != "" and agent_id != "" do
    list_registered(company_id)
    |> Enum.filter(fn tool ->
      ToolGrants.authorize_call(company_id, agent_id, tool.name) == :allow
    end)
  end

  def list_allowed_for_agent(_, _), do: []

  @doc """
  Converts a registered tool to the MCP tools/list shape.
  """
  def to_mcp_descriptor(%RegisteredTool{} = tool) do
    %{
      name: tool.name,
      description: tool.description || "Dynamic tool",
      inputSchema: tool.input_schema || %{},
      dynamic: true,
      plugin_id: tool.plugin_id
    }
  end

  defp do_register(attrs) do
    company_id = attrs.company_id
    name = attrs.name

    case get_active(company_id, name) do
      {:ok, existing} ->
        existing
        |> RegisteredTool.changeset(Map.drop(attrs, [:company_id, :name, :status]))
        |> Repo.update()
        |> tap_audit("mcp_tool_updated")

      {:error, :not_found} ->
        # Re-activate a previously unregistered row with the same name if present.
        case Repo.one(
               from t in RegisteredTool,
                 where: t.company_id == ^company_id and t.name == ^name,
                 order_by: [desc: t.updated_at],
                 limit: 1
             ) do
          nil ->
            %RegisteredTool{}
            |> RegisteredTool.changeset(Map.put(attrs, :status, "active"))
            |> Repo.insert()
            |> tap_audit("mcp_tool_registered")

          %RegisteredTool{} = prior ->
            prior
            |> RegisteredTool.changeset(Map.put(attrs, :status, "active"))
            |> Repo.update()
            |> tap_audit("mcp_tool_reregistered")
        end
    end
  end

  defp normalize_definition(definition, company_id) do
    name =
      definition
      |> Map.get("name", Map.get(definition, :name))
      |> case do
        n when is_binary(n) -> normalize_name(n)
        _ -> nil
      end

    if is_nil(name) or name == "" do
      {:error, :missing_tool_name}
    else
      input_schema =
        definition
        |> Map.get(
          "inputSchema",
          Map.get(
            definition,
            :inputSchema,
            Map.get(definition, "input_schema", Map.get(definition, :input_schema, %{}))
          )
        )
        |> normalize_map()

      description =
        Map.get(definition, "description", Map.get(definition, :description))

      plugin_id =
        Map.get(definition, "plugin_id", Map.get(definition, :plugin_id))

      metadata =
        definition
        |> Map.get("metadata", Map.get(definition, :metadata, %{}))
        |> normalize_map()

      %{
        company_id: company_id,
        name: name,
        description: description,
        input_schema: input_schema,
        plugin_id: plugin_id,
        metadata: metadata,
        status: "active"
      }
    end
  end

  defp normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}

  defp tap_audit({:ok, tool} = ok, action_type) do
    GovernanceAuditLogs.log_action(
      action_type,
      {"system", "system"},
      "Dynamic MCP tool #{action_type}: #{tool.name}",
      resource: tool,
      company_id: tool.company_id,
      metadata: %{
        tool_id: tool.id,
        tool_name: tool.name,
        plugin_id: tool.plugin_id
      }
    )

    ok
  end

  defp tap_audit(other, _action_type), do: other
end
