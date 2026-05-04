defmodule Cympho.Mcp.Server do
  @moduledoc """
  MCP (Model Context Protocol) server implementation for Cympho.

  Exposes project management capabilities as tools that AI models can invoke:
  - Issue CRUD and search
  - Project listing
  - Agent status queries
  - Kanban board state
  """

  alias Cympho.{Issues, Projects, Agents}

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
        inputSchema: %{
          type: "object",
          properties: %{}
        }
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

  def call_tool("list_issues", args) do
    params = Map.take(args, ["status", "priority", "assignee_id", "project_id", "search"])

    limit = Map.get(args, "limit", 20)
    params = Map.put(params, "per_page", to_string(limit))

    result = Issues.list_issues_paginated(params)

    issues = Enum.map(result.issues, &summarize_issue/1)

    %{
      total: result.total,
      page: result.page,
      per_page: result.per_page,
      issues: issues
    }
  end

  def call_tool("get_issue", %{"issue_id" => id}) do
    issue = Issues.get_issue!(id)

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
  end

  def call_tool("create_issue", args) do
    attrs = %{
      title: args["title"],
      description: Map.get(args, "description", ""),
      priority: String.to_atom(Map.get(args, "priority", "medium")),
      status: :todo
    }

    attrs =
      if project_id = args["project_id"] do
        Map.put(attrs, :project_id, project_id)
      else
        attrs
      end

    case Issues.create_issue(attrs) do
      {:ok, issue} -> %{success: true, issue: summarize_issue(issue)}
      {:error, changeset} -> %{success: false, errors: format_errors(changeset)}
    end
  end

  def call_tool("list_projects", _args) do
    Projects.list_projects()
    |> Enum.map(fn p -> %{id: p.id, name: p.name, prefix: p.prefix} end)
  end

  def call_tool("list_agents", args) do
    agents = Agents.list_agents()

    agents =
      if status = args["status"] do
        Enum.filter(agents, fn a -> to_string(a.status) == status end)
      else
        agents
      end

    Enum.map(agents, fn a ->
      %{id: a.id, name: a.name, status: a.status, role: a.role}
    end)
  end

  def call_tool("get_kanban_state", args) do
    params = if project_id = args["project_id"], do: %{"project_id" => project_id}, else: %{}
    result = Issues.list_issues_paginated(Map.put(params, "per_page", "1000"))

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

  def call_tool("search", %{"query" => query}) do
    Cympho.Search.search(query)
  end

  def call_tool(_name, _args) do
    %{error: "Unknown tool"}
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
end
