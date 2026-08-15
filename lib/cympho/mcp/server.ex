defmodule Cympho.Mcp.Server do
  @moduledoc """
  MCP (Model Context Protocol) server implementation for Cympho.

  Every tool requires an authenticated agent (`call_tool/3`) and is scoped to
  that agent's `company_id`. Cross-tenant access is impossible by construction:
  the company_id is taken from the authenticated agent, never from request
  args.

  Built-in tools are always listed. Dynamically registered tools
  (`Cympho.Mcp.ToolRegistry`) are merged into the list only when
  `Cympho.Mcp.ToolGrants.authorize_call/3` returns `:allow` for the calling
  agent. Revocation hides them immediately.
  """

  import Ecto.Query, only: [from: 2]
  require Logger

  alias Cympho.{Agents, Comments, GovernanceAuditLogs, Issues, Repo, Search, Skills}
  alias Cympho.Agents.Agent
  alias Cympho.Mcp.{ToolGrants, ToolRegistry}
  alias Cympho.Plugins.Runtime
  alias Cympho.RateLimiting.AgentActionLimiter

  # Stable error body returned to MCP clients when a mutation is throttled.
  # Shape is intentional and part of the external contract — do not rename keys.
  @rate_limited_error %{error: "rate_limited", success: false}

  # Plugin tools reach third-party services; 5 seconds (the GenServer.call
  # default) is not a realistic budget for one. Overridable at runtime via
  # `config :cympho, :mcp_dynamic_tool_timeout_ms`.
  @dynamic_tool_timeout_ms 30_000

  def tools do
    static_tools()
  end

  @doc """
  Built-in tools plus dynamic tools the agent is explicitly allowed to call.
  """
  def tools_for(%Agent{} = agent) do
    dynamic =
      agent.company_id
      |> ToolRegistry.list_allowed_for_agent(agent.id)
      |> Enum.map(&ToolRegistry.to_mcp_descriptor/1)

    static_tools() ++ dynamic
  end

  def tools_for(_), do: static_tools()

  defp static_tools do
    [
      %{
        name: "list_issues",
        description:
          "List issues with optional filtering by status, priority, assignee, assigned role, or project.",
        inputSchema: %{
          type: "object",
          properties: %{
            status: %{
              type: "string",
              description:
                "Filter by status: backlog, todo, in_progress, in_review, done, blocked"
            },
            priority: %{
              type: "string",
              description: "Filter by priority: critical, high, medium, low"
            },
            assignee_id: %{type: "string", description: "Filter by assignee agent ID"},
            assigned_role: %{type: "string", description: "Filter by assigned role"},
            project_id: %{type: "string", description: "Filter by project ID"},
            search: %{type: "string", description: "Search in issue titles and descriptions"},
            limit: %{
              type: "integer",
              description: "Max results to return (default 20)",
              default: 20
            }
          }
        }
      },
      %{
        name: "get_issue",
        description: "Get detailed information about a specific issue including recent comments.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue_id: %{type: "string", description: "The issue ID"}
          },
          required: ["issue_id"]
        }
      },
      %{
        name: "list_issue_comments",
        description:
          "List comments for a company-scoped issue in chronological order, newest window first.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue_id: %{type: "string", description: "The issue ID"},
            limit: %{
              type: "integer",
              description: "Max comments to return (default 20, max 100)",
              default: 20
            }
          },
          required: ["issue_id"]
        }
      },
      %{
        name: "create_issue_comment",
        description: "Create an agent-authored comment on a company-scoped issue.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue_id: %{type: "string", description: "The issue ID"},
            body: %{type: "string", description: "Comment body"}
          },
          required: ["issue_id", "body"]
        }
      },
      %{
        name: "create_issue",
        description: "Create a new issue in a project.",
        inputSchema: %{
          type: "object",
          properties: %{
            title: %{type: "string", description: "Issue title"},
            description: %{type: "string", description: "Issue description"},
            priority: %{
              type: "string",
              description: "Priority: critical, high, medium, low",
              default: "medium"
            },
            project_id: %{type: "string", description: "Project ID to create the issue in"},
            assigned_role: %{
              type: "string",
              description:
                "Optional role to route the issue to: ceo, cto, engineer, product_manager, designer, qa_engineer, release_engineer, researcher, marketer, content_strategist, sales_development, customer_support"
            },
            assignee_id: %{
              type: "string",
              description:
                "Optional company agent ID to assign directly. When provided with assigned_role, the role must match that agent."
            }
          },
          required: ["title"]
        }
      },
      %{
        name: "list_projects",
        description: "List all projects with their issue counts.",
        inputSchema: %{type: "object", properties: %{}}
      },
      %{
        name: "list_agents",
        description: "List all agents and their current status.",
        inputSchema: %{
          type: "object",
          properties: %{
            status: %{type: "string", description: "Filter by agent status"}
          }
        }
      },
      %{
        name: "get_kanban_state",
        description: "Get the current kanban board state with issue counts per column.",
        inputSchema: %{
          type: "object",
          properties: %{
            project_id: %{type: "string", description: "Optional project ID to filter"}
          }
        }
      },
      %{
        name: "search",
        description: "Search across issues, projects, and agents.",
        inputSchema: %{
          type: "object",
          properties: %{
            query: %{type: "string", description: "Search query"}
          },
          required: ["query"]
        }
      }
    ]
  end

  def call_tool(name, args, %Agent{} = agent) do
    result = do_call(name, args || %{}, agent)
    _ = record_trace(name, args, agent, result)
    result
  rescue
    e ->
      error = %{error: "Internal error", detail: Exception.message(e)}
      _ = record_trace(name, args, agent, error)
      error
  end

  # Tool-call traces are a governance surface — a hash-chained record of which
  # agent invoked which tool — but nothing in production wrote to it. Its only
  # producer was `AgentRunner.extract_and_send_tool_calls/3`, which scans a
  # Messages-API-shaped `content` array; the stock `claude --output-format json`
  # envelope this codebase builds has no such key, so the whole subsystem ran on
  # synthetic test messages. MCP is a real tool-call boundary: every call here is
  # an authenticated agent invoking a named tool, which is exactly what the
  # subsystem is meant to record.
  #
  # Never let tracing break a tool call.
  defp record_trace(name, args, %Agent{} = agent, result) do
    {status, error_message} = trace_outcome(result)

    Cympho.ToolCallTraces.create_tool_call_trace(%{
      trace_type: "mcp_tool_call",
      tool_name: to_string(name),
      # Arguments and results are redacted by ToolCallTraces before they land.
      tool_arguments: normalize_trace_arguments(args),
      error_message: error_message,
      status: status,
      company_id: agent.company_id,
      agent_id: agent.id,
      actor_type: "agent",
      actor_id: agent.id,
      occurred_at: DateTime.utc_now()
    })
  rescue
    exception ->
      Logger.warning("failed to record MCP tool call trace",
        component: "mcp",
        company_id: agent.company_id,
        agent_id: agent.id,
        reason: Exception.message(exception)
      )

      :ok
  end

  defp trace_outcome(%{success: false} = result), do: {"error", trace_error(result)}
  defp trace_outcome(%{error: _} = result), do: {"error", trace_error(result)}
  defp trace_outcome(_result), do: {"success", nil}

  defp trace_error(%{error: error}) when is_binary(error), do: error
  defp trace_error(%{error: error}), do: inspect(error)
  defp trace_error(_result), do: "tool call failed"

  defp normalize_trace_arguments(args) when is_map(args), do: args
  defp normalize_trace_arguments(_args), do: %{}

  defp static_tool_names do
    Enum.map(static_tools(), & &1.name)
  end

  defp do_call(name, args, agent) when is_binary(name) do
    if name in static_tool_names() do
      do_static_call(name, args, agent)
    else
      do_dynamic_call(name, args, agent)
    end
  end

  defp do_call(_name, _args, _agent) do
    %{error: "Unknown or malformed tool invocation"}
  end

  defp do_dynamic_call(name, args, %Agent{} = agent) do
    decision = ToolGrants.authorize_call(agent.company_id, agent.id, name)

    case decision do
      :allow ->
        case ToolRegistry.get_active(agent.company_id, name) do
          {:ok, tool} ->
            invoke_dynamic_tool(tool, args, agent)

          {:error, :not_found} ->
            %{error: "Tool not authorized", decision: "deny"}
        end

      other when other in [:deny, :pending, :revoked] ->
        %{error: "Tool not authorized", decision: Atom.to_string(other)}
    end
  end

  defp invoke_dynamic_tool(tool, args, %Agent{} = agent) do
    plugin_not_found = %{
      success: false,
      dynamic: true,
      tool: tool.name,
      error: ":plugin_not_found"
    }

    case tool.plugin_id do
      plugin_id when is_binary(plugin_id) ->
        case Skills.get_company_plugin(agent.company_id, plugin_id) do
          {:ok, plugin} ->
            case Runtime.whereis(plugin) do
              nil ->
                plugin_not_found

              pid ->
                case execute_plugin_tool(pid, tool, args, agent) do
                  {:ok, result} ->
                    %{
                      success: true,
                      dynamic: true,
                      tool: tool.name,
                      plugin_id: plugin_id,
                      result: result
                    }

                  {:error, reason} ->
                    %{
                      success: false,
                      dynamic: true,
                      tool: tool.name,
                      error: inspect(reason)
                    }
                end
            end

          _ ->
            plugin_not_found
        end

      _ ->
        plugin_not_found
    end
  end

  # Plugin workers run third-party code that typically makes network calls, so
  # the 5s `GenServer.call/2` default was far too short. Worse, a call timeout
  # is an *exit*, which `call_tool/3`'s `rescue` cannot catch — the MCP request
  # 500'd instead of returning the structured error shape every other dynamic
  # tool failure uses, and the caller learned nothing about which tool hung.
  defp execute_plugin_tool(pid, tool, args, agent) do
    request =
      {:execute_tool, tool.name, args || %{}, %{company_id: agent.company_id, agent_id: agent.id}}

    GenServer.call(pid, request, dynamic_tool_timeout())
  catch
    :exit, {:timeout, _call} ->
      {:error, {:tool_timeout, tool.name, dynamic_tool_timeout()}}

    :exit, {:noproc, _call} ->
      {:error, {:plugin_unavailable, tool.name}}

    :exit, reason ->
      {:error, {:plugin_exit, tool.name, inspect(reason)}}
  end

  defp dynamic_tool_timeout do
    Application.get_env(:cympho, :mcp_dynamic_tool_timeout_ms, @dynamic_tool_timeout_ms)
  end

  defp do_static_call("list_issues", args, agent) do
    params =
      args
      |> Map.take(["status", "priority", "assignee_id", "assigned_role", "project_id", "search"])
      |> Map.put("company_id", agent.company_id)
      |> Map.put("per_page", to_string(Map.get(args, "limit", 20)))

    result = Issues.list_issues_paginated(params)

    %{
      total: result.total,
      page: result.page,
      per_page: result.per_page,
      issues: Enum.map(result.issues, &summarize_issue/1)
    }
  end

  defp do_static_call("get_issue", %{"issue_id" => id}, agent) do
    case Issues.get_company_issue(agent.company_id, id) do
      {:ok, issue} ->
        comments = Comments.list_comments(issue.id)

        %{
          id: issue.id,
          title: issue.title,
          description: issue.description,
          status: issue.status,
          priority: issue.priority,
          assignee: issue.assignee && %{id: issue.assignee.id, name: issue.assignee.name},
          project:
            issue.project &&
              %{id: issue.project.id, name: issue.project.name, prefix: issue.project.prefix},
          comments_count: length(comments),
          comments: comments |> recent_comments(10) |> Enum.map(&summarize_comment/1),
          inserted_at: issue.inserted_at,
          updated_at: issue.updated_at
        }

      {:error, :not_found} ->
        %{error: "Issue not found"}
    end
  end

  defp do_static_call("list_issue_comments", %{"issue_id" => id} = args, agent) do
    case Issues.get_company_issue(agent.company_id, id) do
      {:ok, issue} ->
        comments = Comments.list_comments(issue.id)
        limit = parse_limit(args["limit"], 20, 100)

        %{
          issue_id: issue.id,
          total: length(comments),
          limit: limit,
          comments: comments |> recent_comments(limit) |> Enum.map(&summarize_comment/1)
        }

      {:error, :not_found} ->
        %{error: "Issue not found"}
    end
  end

  defp do_static_call("create_issue_comment", %{"issue_id" => id, "body" => body}, agent)
       when is_binary(body) do
    body = String.trim(body)

    with :ok <- authorize_mutation("create_issue_comment", agent),
         :ok <- validate_comment_body(body),
         {:ok, issue} <- Issues.get_company_issue(agent.company_id, id),
         {:ok, comment} <-
           Comments.create_comment(%{
             issue_id: issue.id,
             body: body,
             author_type: "agent",
             author_id: agent.id
           }) do
      %{success: true, comment: summarize_comment(comment)}
    else
      {:error, :rate_limited} -> @rate_limited_error
      {:error, :not_found} -> %{error: "Issue not found"}
      {:error, errors} when is_map(errors) -> %{success: false, errors: errors}
      {:error, changeset} -> %{success: false, errors: format_errors(changeset)}
    end
  end

  defp do_static_call("create_issue", args, agent) do
    project_id =
      case args["project_id"] do
        nil ->
          nil

        id when is_binary(id) ->
          if project_belongs_to_company?(id, agent.company_id), do: id, else: :forbidden
      end

    with :ok <- authorize_mutation("create_issue", agent),
         :ok <- validate_project_id(project_id),
         {:ok, routing_attrs} <- routing_attrs(args, agent.company_id) do
      attrs =
        %{
          title: args["title"],
          description: Map.get(args, "description", ""),
          priority: parse_priority(Map.get(args, "priority", "medium")),
          status: :todo,
          company_id: agent.company_id,
          actor_type: "agent",
          actor_id: agent.id,
          created_by_agent_id: agent.id,
          origin_type: "mcp",
          origin_id: agent.id
        }
        |> Map.merge(routing_attrs)
        |> maybe_put(:project_id, project_id)

      case Issues.create_issue(attrs) do
        {:ok, issue} -> %{success: true, issue: summarize_issue(issue)}
        {:error, changeset} -> %{success: false, errors: format_errors(changeset)}
      end
    else
      {:error, :rate_limited} -> @rate_limited_error
      {:error, errors} -> %{success: false, errors: errors}
    end
  end

  defp do_static_call("list_projects", _args, agent) do
    Cympho.Companies.list_company_projects(agent.company_id)
    |> Enum.map(fn p -> %{id: p.id, name: p.name, prefix: p.prefix} end)
  end

  defp do_static_call("list_agents", args, agent) do
    agents =
      Cympho.Companies.list_company_agents(agent.company_id)
      |> filter_by_status(args["status"])

    Enum.map(agents, fn a ->
      %{id: a.id, name: a.name, status: a.status, role: a.role}
    end)
  end

  defp do_static_call("get_kanban_state", args, agent) do
    params = %{"company_id" => agent.company_id, "per_page" => "1000"}

    params =
      case args["project_id"] do
        nil ->
          params

        id when is_binary(id) ->
          if project_belongs_to_company?(id, agent.company_id),
            do: Map.put(params, "project_id", id),
            else: params
      end

    result = Issues.list_issues_paginated(params)
    by_status = Enum.group_by(result.issues, & &1.status)

    Enum.map(Issues.Issue.status_options(), fn status ->
      issues = Map.get(by_status, status, [])

      %{
        status: status,
        count: length(issues),
        issues: Enum.map(issues, &summarize_issue/1)
      }
    end)
  end

  defp do_static_call("search", %{"query" => query}, agent) when is_binary(query) do
    Search.search(query, company_id: agent.company_id)
  end

  defp do_static_call(_name, _args, _agent) do
    %{error: "Unknown or malformed tool invocation"}
  end

  # Rate-limit + audit gate for MCP mutations that can auto-ignite wakes or
  # otherwise amplify spend. Fail-closed when company_id is missing.
  defp authorize_mutation(tool, %Agent{id: agent_id, company_id: company_id} = agent)
       when is_binary(agent_id) and is_binary(company_id) do
    case AgentActionLimiter.check_for_company(agent_id, company_id) do
      :ok ->
        audit_authorize(agent, tool, "allowed")
        :ok

      {:error, :rate_limited} ->
        audit_authorize(agent, tool, "rate_limited")

        Logger.warning("MCP mutation rate limited",
          agent_id: agent_id,
          company_id: company_id,
          component: "mcp",
          tool: tool
        )

        {:error, :rate_limited}
    end
  end

  defp authorize_mutation(tool, agent) do
    audit_authorize(agent, tool, "denied")
    {:error, :rate_limited}
  end

  defp audit_authorize(%Agent{} = agent, tool, decision) when is_binary(tool) do
    _ =
      GovernanceAuditLogs.log_action(
        "mcp_mutation_authorize",
        agent,
        decision,
        company_id: agent.company_id,
        reasoning: "MCP #{tool} authorize decision: #{decision}",
        metadata: %{
          "tool" => tool,
          "decision" => decision,
          "surface" => "mcp"
        }
      )

    :ok
  rescue
    e ->
      Logger.warning("MCP authorize audit failed",
        agent_id: Map.get(agent, :id),
        company_id: Map.get(agent, :company_id),
        component: "mcp",
        error: Exception.message(e)
      )

      :ok
  end

  defp audit_authorize(_agent, _tool, _decision), do: :ok

  defp summarize_issue(issue) do
    %{
      id: issue.id,
      title: issue.title,
      status: issue.status,
      priority: issue.priority,
      assignee: assoc_field(issue, :assignee, :name),
      assignee_id: Map.get(issue, :assignee_id),
      assigned_role: Map.get(issue, :assigned_role),
      project: assoc_field(issue, :project, :prefix)
    }
  end

  defp summarize_comment(comment) do
    %{
      id: comment.id,
      body: comment.body,
      author_type: comment.author_type,
      author_id: comment.author_id,
      inserted_at: comment.inserted_at,
      updated_at: comment.updated_at
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp parse_priority(p) when p in ["critical", "high", "medium", "low"], do: String.to_atom(p)
  defp parse_priority(_), do: :medium

  defp parse_limit(value, _default, max) when is_integer(value),
    do: value |> max(1) |> min(max)

  defp parse_limit(value, default, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parse_limit(parsed, default, max)
      _ -> default
    end
  end

  defp parse_limit(_value, default, _max), do: default

  defp recent_comments(comments, limit) do
    comments
    |> Enum.take(-limit)
  end

  defp validate_comment_body(""), do: {:error, %{body: ["can't be blank"]}}
  defp validate_comment_body(_body), do: :ok

  defp validate_project_id(:forbidden),
    do: {:error, %{project_id: ["does not belong to this company"]}}

  defp validate_project_id(_project_id), do: :ok

  defp routing_attrs(args, company_id) do
    with {:ok, role} <- normalize_assigned_role(Map.get(args, "assigned_role")),
         {:ok, assignee} <- load_assignee(Map.get(args, "assignee_id"), company_id),
         :ok <- validate_assignee_role(assignee, role) do
      attrs = %{}

      attrs =
        case role || (assignee && assignee.role) do
          nil -> attrs
          role -> Map.put(attrs, :assigned_role, Atom.to_string(role))
        end

      attrs =
        if assignee do
          Map.put(attrs, :assignee_id, assignee.id)
        else
          attrs
        end

      {:ok, attrs}
    end
  end

  defp normalize_assigned_role(nil), do: {:ok, nil}
  defp normalize_assigned_role(""), do: {:ok, nil}

  defp normalize_assigned_role(role) do
    case Agent.normalize_role(role) do
      nil -> {:error, %{assigned_role: ["is not a supported agent role"]}}
      normalized -> {:ok, normalized}
    end
  end

  defp load_assignee(nil, _company_id), do: {:ok, nil}
  defp load_assignee("", _company_id), do: {:ok, nil}

  defp load_assignee(assignee_id, company_id) when is_binary(assignee_id) do
    case Agents.get_company_agent(company_id, assignee_id) do
      {:ok, agent} -> {:ok, agent}
      {:error, :not_found} -> {:error, %{assignee_id: ["does not belong to this company"]}}
    end
  end

  defp load_assignee(_assignee_id, _company_id),
    do: {:error, %{assignee_id: ["must be a company agent ID"]}}

  defp validate_assignee_role(nil, _role), do: :ok
  defp validate_assignee_role(_assignee, nil), do: :ok

  defp validate_assignee_role(%Agent{role: role}, role), do: :ok

  defp validate_assignee_role(%Agent{role: role}, expected_role) do
    {:error,
     %{
       assignee_id: [
         "has role #{Atom.to_string(role)} and cannot be assigned as #{Atom.to_string(expected_role)}"
       ]
     }}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp assoc_field(issue, assoc, field) do
    case Map.get(issue, assoc) do
      %Ecto.Association.NotLoaded{} -> nil
      nil -> nil
      struct -> Map.get(struct, field)
    end
  end

  defp filter_by_status(agents, nil), do: agents

  defp filter_by_status(agents, status) when is_binary(status) do
    Enum.filter(agents, fn a -> to_string(a.status) == status end)
  end

  defp project_belongs_to_company?(project_id, company_id) do
    Repo.exists?(
      from p in Cympho.Projects.Project,
        where: p.id == ^project_id and p.company_id == ^company_id
    )
  end
end
