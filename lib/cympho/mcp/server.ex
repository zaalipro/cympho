defmodule Cympho.Mcp.Server do
  @moduledoc """
  MCP (Model Context Protocol) server implementation for Cympho.

  Every tool requires an authenticated agent (`call_tool/3`) and is scoped to
  that agent's `company_id`. Cross-tenant access is impossible by construction:
  the company_id is taken from the authenticated agent, never from request
  args.
  """

  import Ecto.Query, only: [from: 2]
  alias Cympho.{Agents, Issues, Repo, Search}
  alias Cympho.Agents.Agent

  def tools do
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
    do_call(name, args || %{}, agent)
  rescue
    e ->
      %{error: "Internal error", detail: Exception.message(e)}
  end

  defp do_call("list_issues", args, agent) do
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

    with :ok <- validate_project_id(project_id),
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
      {:error, errors} -> %{success: false, errors: errors}
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
      assignee: assoc_field(issue, :assignee, :name),
      assignee_id: Map.get(issue, :assignee_id),
      assigned_role: Map.get(issue, :assigned_role),
      project: assoc_field(issue, :project, :prefix)
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
