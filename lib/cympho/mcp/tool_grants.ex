defmodule Cympho.Mcp.ToolGrants do
  @moduledoc """
  Explicit per-agent (or company-wide) grants for dynamically registered MCP tools.

  Authorization is fail-closed: missing company scope, unregistered tools, or
  absent grants all resolve to `:deny`. Grant decisions are audited.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Cympho.GovernanceAuditLogs
  alias Cympho.Mcp.{RegisteredTool, ToolGrant, ToolRegistry}
  alias Cympho.Repo
  alias Cympho.Skills.Plugin

  @type decision :: :allow | :deny | :pending | :revoked

  @doc """
  Creates a grant for a dynamic tool.

  Required attrs: `:company_id`, `:tool_name`, `:status` (`allow|deny|pending`).
  Optional: `:agent_id` (nil = company-wide), `:tool_id`, `:reason`,
  `:granted_by_type`, `:granted_by_id`, `:metadata`.
  """
  @spec create_grant(map()) :: {:ok, ToolGrant.t()} | {:error, term()}
  def create_grant(attrs) when is_map(attrs) do
    company_id = fetch(attrs, :company_id)
    tool_name = fetch(attrs, :tool_name) || fetch(attrs, :name)
    status = fetch(attrs, :status) || "pending"

    cond do
      not is_binary(company_id) or company_id == "" ->
        {:error, :invalid_company_scope}

      not is_binary(tool_name) or tool_name == "" ->
        {:error, :missing_tool_name}

      status not in ToolGrant.statuses() or status == "revoked" ->
        {:error, :invalid_status}

      true ->
        tool_name = String.downcase(String.trim(tool_name))

        with {:ok, tool} <- resolve_tool(company_id, tool_name, fetch(attrs, :tool_id)) do
          grant_attrs = %{
            company_id: company_id,
            tool_id: tool && tool.id,
            tool_name: tool_name,
            agent_id: fetch(attrs, :agent_id),
            status: status,
            reason: fetch(attrs, :reason),
            granted_by_type: fetch(attrs, :granted_by_type) || "system",
            granted_by_id: fetch(attrs, :granted_by_id) || "system",
            metadata: normalize_map(fetch(attrs, :metadata) || %{})
          }

          %ToolGrant{}
          |> ToolGrant.changeset(grant_attrs)
          |> Repo.insert()
          |> case do
            {:ok, grant} ->
              audit_grant(grant, "mcp_tool_grant_created")
              {:ok, grant}

            error ->
              error
          end
        end
    end
  end

  def create_grant(_), do: {:error, :invalid_attrs}

  @doc """
  Authorizes a dynamic tool call for an agent within a company.

  Returns `:allow | :deny | :pending | :revoked`. Missing company/agent/tool,
  unregistered tools, and absent grants all fail closed to `:deny`.
  """
  @spec authorize_call(String.t(), String.t(), String.t()) :: decision()
  def authorize_call(company_id, agent_id, tool_name)
      when is_binary(company_id) and is_binary(agent_id) and is_binary(tool_name) and
             company_id != "" and agent_id != "" and tool_name != "" do
    tool_name = String.downcase(String.trim(tool_name))

    case ToolRegistry.get_active(company_id, tool_name) do
      {:error, :not_found} ->
        :deny

      {:ok, tool} ->
        if owning_plugin_active?(tool) do
          case latest_applicable_grant(company_id, agent_id, tool_name) do
            nil -> :deny
            %ToolGrant{status: "allow"} -> :allow
            %ToolGrant{status: "deny"} -> :deny
            %ToolGrant{status: "pending"} -> :pending
            %ToolGrant{status: "revoked"} -> :revoked
            _ -> :deny
          end
        else
          :deny
        end
    end
  end

  def authorize_call(_company_id, _agent_id, _tool_name), do: :deny

  @doc """
  Revokes a grant by id. Immediate: subsequent authorize_call returns `:revoked`
  and the tool is hidden from MCP tools/list for that principal.
  """
  @spec revoke(String.t(), String.t() | nil) :: {:ok, ToolGrant.t()} | {:error, term()}
  def revoke(grant_id, reason \\ nil)

  def revoke(grant_id, reason) when is_binary(grant_id) and grant_id != "" do
    case Repo.get(ToolGrant, grant_id) do
      nil ->
        {:error, :not_found}

      %ToolGrant{status: "revoked"} = grant ->
        {:ok, grant}

      %ToolGrant{} = grant ->
        grant
        |> ToolGrant.revoke_changeset(reason)
        |> Repo.update()
        |> case do
          {:ok, revoked} ->
            audit_grant(revoked, "mcp_tool_grant_revoked", reason)
            {:ok, revoked}

          error ->
            error
        end
    end
  end

  def revoke(_, _), do: {:error, :invalid_grant_id}

  @doc """
  Revokes every non-revoked grant for a tool within a company (used on unregister).
  """
  @spec revoke_all_for_tool(String.t(), String.t(), String.t() | nil) :: non_neg_integer()
  def revoke_all_for_tool(company_id, tool_name, reason \\ nil)
      when is_binary(company_id) and is_binary(tool_name) do
    tool_name = String.downcase(String.trim(tool_name))

    from(g in ToolGrant,
      where: g.company_id == ^company_id and g.tool_name == ^tool_name and g.status != "revoked"
    )
    |> Repo.all()
    |> Enum.reduce(0, fn grant, count ->
      case revoke(grant.id, reason) do
        {:ok, _} -> count + 1
        _ -> count
      end
    end)
  end

  @doc """
  Lists grants for a company, optionally filtered by tool_name, agent_id, status.
  """
  def list_grants(company_id, opts \\ [])

  def list_grants(company_id, opts) when is_binary(company_id) and is_list(opts) do
    query =
      from(g in ToolGrant,
        where: g.company_id == ^company_id,
        order_by: [desc: g.inserted_at]
      )

    query =
      Enum.reduce(opts, query, fn
        {:tool_name, name}, q when is_binary(name) ->
          where(q, [g], g.tool_name == ^String.downcase(String.trim(name)))

        {:agent_id, id}, q when is_binary(id) ->
          where(q, [g], g.agent_id == ^id)

        {:status, status}, q when is_binary(status) ->
          where(q, [g], g.status == ^status)

        _, q ->
          q
      end)

    Repo.all(query)
  end

  def list_grants(_, _), do: []
  # Prefer the latest agent-specific grant; fall back to company-wide (agent_id nil).
  # Order by sequence (monotonic bigserial) then inserted_at for stable "latest".
  defp latest_applicable_grant(company_id, agent_id, tool_name) do
    agent_grant =
      from(g in ToolGrant,
        where:
          g.company_id == ^company_id and g.tool_name == ^tool_name and g.agent_id == ^agent_id,
        order_by: [desc: g.sequence, desc: g.inserted_at],
        limit: 1
      )
      |> Repo.one()

    if agent_grant do
      agent_grant
    else
      from(g in ToolGrant,
        where: g.company_id == ^company_id and g.tool_name == ^tool_name and is_nil(g.agent_id),
        order_by: [desc: g.sequence, desc: g.inserted_at],
        limit: 1
      )
      |> Repo.one()
    end
  end

  defp resolve_tool(company_id, tool_name, tool_id) when is_binary(tool_id) do
    case Repo.get(RegisteredTool, tool_id) do
      %RegisteredTool{company_id: ^company_id, name: ^tool_name, status: "active"} = tool ->
        {:ok, tool}

      %RegisteredTool{company_id: ^company_id, status: "active"} = tool ->
        # tool_id wins if company matches and tool is active
        {:ok, tool}

      %RegisteredTool{} ->
        {:error, :tool_company_mismatch}

      nil ->
        ToolRegistry.get_active(company_id, tool_name)
        |> case do
          {:ok, tool} -> {:ok, tool}
          {:error, :not_found} -> {:ok, nil}
        end
    end
  end

  defp resolve_tool(company_id, tool_name, _tool_id) do
    case ToolRegistry.get_active(company_id, tool_name) do
      {:ok, tool} -> {:ok, tool}
      # Allow grants against a name even if not yet active (pending approval flow);
      # authorize_call still requires an active registration.
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp owning_plugin_active?(%RegisteredTool{plugin_id: nil}), do: true

  defp owning_plugin_active?(%RegisteredTool{
         plugin_id: plugin_id,
         company_id: company_id
       }) do
    case Repo.get(Plugin, plugin_id) do
      %Plugin{company_id: ^company_id, enabled: true, status: "active"} -> true
      _plugin -> false
    end
  end

  defp audit_grant(grant, action_type, reason \\ nil) do
    GovernanceAuditLogs.log_action(
      action_type,
      {grant.granted_by_type || "system", grant.granted_by_id || "system"},
      "MCP tool grant #{grant.status}: #{grant.tool_name}",
      resource: grant,
      company_id: grant.company_id,
      reasoning: reason || grant.reason,
      metadata: %{
        grant_id: grant.id,
        tool_name: grant.tool_name,
        tool_id: grant.tool_id,
        agent_id: grant.agent_id,
        status: grant.status
      }
    )
  end

  defp fetch(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_map(map) when is_map(map), do: map
  defp normalize_map(_), do: %{}
end
