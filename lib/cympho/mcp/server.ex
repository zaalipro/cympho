defmodule Cympho.Mcp.Server do
  @moduledoc """
  MCP (Model Context Protocol) server implementation for Cympho.

  Every tool requires an authenticated agent (`call_tool/3`) and is scoped to
  that agent's `company_id`. Cross-tenant access is impossible by construction:
  the company_id is taken from the authenticated agent, never from request
  args.
  """

  import Ecto.Query, only: [from: 2]
  alias Cympho.{Issues, Repo, Search}
  alias Cympho.Agents.Agent

  def tools do
    [
      %{
        name: "list_issues",
        description:
          "List issues with optional filtering by status, priority, assignee, or project.",
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
        description:
          "Get detailed information about a specific issue including comments and activity.",
        inputSchema: %{
          type: "object",
          properties: %{
            issue_id: %{type: "string", description: "The issue ID"}
          },
          required: ["issue_id"]
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
            project_id: %{type: "string", description: "Project ID to create the issue in"}
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
    do_call(name, args || %{}, agent)
  rescue
    e ->
      %{error: "Internal error", detail: Exception.message(e)}
  end

  defp do_call("list_issues", args, agent) do
    params =
      args
      |> Map.take(["status", "priority", "assignee_id", "project_id", "search"])
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

  defp do_call("get_issue", %{"issue_id" => id}, agent) do
    case Issues.get_company_issue(agent.company_id, id) do
      {:ok, issue} ->
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
          comments_count: length(issue.comments),
          inserted_at: issue.inserted_at,
          updated_at: issue.updated_at
        }

      {:error, :not_found} ->
        %{error: "Issue not found"}
    end
  end

  defp do_call("create_issue", args, agent) do
    project_id =
      case args["project_id"] do
        nil ->
          nil

        id when is_binary(id) ->
          if project_belongs_to_company?(id, agent.company_id), do: id, else: :forbidden
      end

    if project_id == :forbidden do
      %{success: false, errors: %{project_id: ["does not belong to this company"]}}
    else
      attrs =
        %{
          title: args["title"],
          description: Map.get(args, "description", ""),
          priority: parse_priority(Map.get(args, "priority", "medium")),
          status: :todo,
          company_id: agent.company_id,
          actor_type: "agent",
          actor_id: agent.id,
          created_by_agent_id: agent.id
        }
        |> maybe_put(:project_id, project_id)

      case Issues.create_issue(attrs) do
        {:ok, issue} -> %{success: true, issue: summarize_issue(issue)}
        {:error, changeset} -> %{success: false, errors: format_errors(changeset)}
      end
    end
  end

  defp do_call("list_projects", _args, agent) do
    Cympho.Companies.list_company_projects(agent.company_id)
    |> Enum.map(fn p -> %{id: p.id, name: p.name, prefix: p.prefix} end)
  end

  defp do_call("list_agents", args, agent) do
    agents =
      Cympho.Companies.list_company_agents(agent.company_id)
      |> filter_by_status(args["status"])

    Enum.map(agents, fn a ->
      %{id: a.id, name: a.name, status: a.status, role: a.role}
    end)
  end

  defp do_call("get_kanban_state", args, agent) do
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

  defp do_call("search", %{"query" => query}, agent) when is_binary(query) do
    Search.search(query, company_id: agent.company_id)
  end

  defp do_call(_name, _args, _agent) do
    %{error: "Unknown or malformed tool invocation"}
  end

  defp summarize_issue(issue) do
    %{
      id: issue.id,
      title: issue.title,
      status: issue.status,
      priority: issue.priority,
      assignee: issue.assignee && issue.assignee.name,
      project: issue.project && issue.project.prefix
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
