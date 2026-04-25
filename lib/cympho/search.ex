defmodule Cympho.Search do
  @moduledoc "Full-text search across issues, agents, projects, and goals using PostgreSQL tsvector."
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Issues.Issue
  alias Cympho.Comments.Comment
  alias Cympho.Agents.Agent
  alias Cympho.Projects.Project
  alias Cympho.Goals.Goal

  def search(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    issues =
      from(i in Issue,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query),
        limit: ^limit,
        preload: [:comments, :blocked_by, :blocks, :assignee]
      )
      |> Repo.all()

    comments =
      from(c in Comment,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query),
        limit: ^limit,
        preload: [:issue]
      )
      |> Repo.all()

    %{issues: issues, comments: comments}
  end

  def search_issues(query, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(i in Issue,
      where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
      order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query),
      limit: ^limit,
      preload: [:comments, :blocked_by, :blocks, :assignee]
    )
    |> Repo.all()
  end

  @doc """
  Advanced search across all entities with filters.
  Returns a map with keys :issues, :agents, :projects, :goals
  """
  def search_all(query, filters \\ %{}, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    %{
      issues: search_issues_with_filters(query, filters, limit: limit, offset: offset),
      agents: search_agents_with_filters(query, filters, limit: limit, offset: offset),
      projects: search_projects_with_filters(query, filters, limit: limit, offset: offset),
      goals: search_goals_with_filters(query, filters, limit: limit, offset: offset)
    }
  end

  defp search_issues_with_filters(query, filters, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query =
      from(i in Issue,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query),
        preload: [:assignee, :project, :goal, :labels]
      )

    base_query
    |> apply_status_filter(filters["status"])
    |> apply_assignee_filter(filters["assignee_id"])
    |> apply_label_filter(filters["label_id"])
    |> apply_project_filter(filters["project_id"])
    |> apply_goal_filter(filters["goal_id"])
    |> apply_date_range_filter(filters["date_from"], filters["date_to"])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp search_agents_with_filters(query, filters, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query =
      from(a in Agent,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query)
      )

    base_query
    |> apply_agent_status_filter(filters["agent_status"])
    |> apply_role_filter(filters["role"])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp search_projects_with_filters(query, filters, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query =
      from(p in Project,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query)
      )

    base_query
    |> apply_project_status_filter(filters["project_status"])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  defp search_goals_with_filters(query, filters, opts) do
    limit = Keyword.get(opts, :limit, 20)
    offset = Keyword.get(opts, :offset, 0)

    base_query =
      from(g in Goal,
        where: fragment("search_vector @@ plainto_tsquery('english', ?)", ^query),
        order_by: fragment("ts_rank(search_vector, plainto_tsquery('english', ?)) DESC", ^query),
        preload: [:project]
      )

    base_query
    |> apply_goal_status_filter(filters["goal_status"])
    |> apply_goal_priority_filter(filters["goal_priority"])
    |> limit(^limit)
    |> offset(^offset)
    |> Repo.all()
  end

  # Filter functions

  defp apply_status_filter(query, nil), do: query
  defp apply_status_filter(query, ""), do: query
  defp apply_status_filter(query, status) do
    from(q in query, where: q.status == ^status)
  end

  defp apply_assignee_filter(query, nil), do: query
  defp apply_assignee_filter(query, ""), do: query
  defp apply_assignee_filter(query, assignee_id) do
    from(q in query, where: q.assignee_id == ^assignee_id)
  end

  defp apply_label_filter(query, nil), do: query
  defp apply_label_filter(query, ""), do: query
  defp apply_label_filter(query, label_id) do
    from(q in query,
      join: l in assoc(q, :labels),
      where: l.id == ^label_id
    )
  end

  defp apply_project_filter(query, nil), do: query
  defp apply_project_filter(query, ""), do: query
  defp apply_project_filter(query, project_id) do
    from(q in query, where: q.project_id == ^project_id)
  end

  defp apply_goal_filter(query, nil), do: query
  defp apply_goal_filter(query, ""), do: query
  defp apply_goal_filter(query, goal_id) do
    from(q in query, where: q.goal_id == ^goal_id)
  end

  defp apply_date_range_filter(query, nil, nil), do: query
  defp apply_date_range_filter(query, date_from, nil) do
    from(q in query, where: q.inserted_at >= ^parse_date(date_from))
  end
  defp apply_date_range_filter(query, nil, date_to) do
    from(q in query, where: q.inserted_at <= ^parse_date(date_to))
  end
  defp apply_date_range_filter(query, date_from, date_to) do
    from(q in query,
      where: q.inserted_at >= ^parse_date(date_from) and q.inserted_at <= ^parse_date(date_to)
    )
  end

  defp apply_agent_status_filter(query, nil), do: query
  defp apply_agent_status_filter(query, ""), do: query
  defp apply_agent_status_filter(query, status) do
    from(q in query, where: q.status == ^status)
  end

  defp apply_role_filter(query, nil), do: query
  defp apply_role_filter(query, ""), do: query
  defp apply_role_filter(query, role) do
    from(q in query, where: q.role == ^role)
  end

  defp apply_project_status_filter(query, nil), do: query
  defp apply_project_status_filter(query, ""), do: query
  defp apply_project_status_filter(query, status) do
    from(q in query, where: q.status == ^status)
  end

  defp apply_goal_status_filter(query, nil), do: query
  defp apply_goal_status_filter(query, ""), do: query
  defp apply_goal_status_filter(query, status) do
    from(q in query, where: q.status == ^status)
  end

  defp apply_goal_priority_filter(query, nil), do: query
  defp apply_goal_priority_filter(query, ""), do: query
  defp apply_goal_priority_filter(query, priority) do
    from(q in query, where: q.priority == ^priority)
  end

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end
  defp parse_date(_), do: nil
end
