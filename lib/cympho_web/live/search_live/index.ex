defmodule CymphoWeb.SearchLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Search
  alias Cympho.RecentSearches
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Goals
  alias Cympho.Projects
  alias Cympho.Labels

  @advanced_filter_keys ~w(goal_id label_id role agent_status project_status goal_status goal_priority)

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    filters = default_filters()

    socket =
      socket
      |> assign(:page_title, "Search")
      |> assign(:query, "")
      |> assign(:results, empty_results())
      |> assign(:recent_searches, recent_searches_for_user(current_user))
      |> assign(:agents, list_agents_scoped(company_id))
      |> assign(:projects, list_projects_scoped(company_id))
      |> assign(:goals, list_goals_scoped(company_id))
      |> assign(:role_options, role_options())
      |> assign(:labels, list_labels_scoped(company_id))
      |> assign(:filters, filters)
      |> assign(:active_tab, :all)
      |> assign(:total_count, 0)
      |> assign(:search_command, empty_search_command(filters))

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query = params["q"] || ""
    active_tab = parse_tab(params["tab"])

    filters = filters_from_params(params)

    socket =
      socket
      |> assign(:query, query)
      |> assign(:filters, filters)
      |> assign(:active_tab, active_tab)
      |> perform_search()
      |> assign(
        :recent_searches,
        recent_searches_for_user(socket.assigns.current_user)
      )

    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"search" => %{"query" => query}}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         build_url(socket, %{
           "q" => query,
           "tab" => to_string(socket.assigns.active_tab),
           "page" => "1"
         })
     )}
  end

  def handle_event("filter", %{"filter" => filter_params}, socket) do
    merged_filters = Map.merge(socket.assigns.filters, filter_params)

    {:noreply,
     push_patch(socket,
       to:
         build_url(
           socket,
           Map.merge(merged_filters, %{
             "q" => socket.assigns.query,
             "tab" => to_string(socket.assigns.active_tab),
             "page" => "1"
           })
         )
     )}
  end

  def handle_event("change_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(socket,
       to:
         build_url(socket, %{
           "q" => socket.assigns.query,
           "tab" => tab,
           "page" => "1"
         })
     )}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     push_patch(socket,
       to: ~p"/search?q=#{socket.assigns.query}&tab=#{socket.assigns.active_tab}"
     )}
  end

  def handle_event("recent_search", %{"query" => query}, socket) do
    {:noreply, push_patch(socket, to: ~p"/search?q=#{query}&tab=#{socket.assigns.active_tab}")}
  end

  def handle_event("clear_recent_searches", _params, socket) do
    current_user = socket.assigns.current_user

    if current_user do
      RecentSearches.clear_recent_searches(current_user.id)
    end

    {:noreply,
     socket
     |> assign(:recent_searches, [])}
  end

  defp perform_search(socket) do
    query = socket.assigns.query
    filters = socket.assigns.filters

    if String.trim(query) == "" do
      socket
      |> assign(:results, empty_results())
      |> assign(:total_count, 0)
      |> assign_search_command()
    else
      company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
      results = Search.search_all(query, filters, limit: 20, company_id: company_id)

      total_count =
        length(results.issues) + length(results.agents) + length(results.projects) +
          length(results.goals)

      current_user = socket.assigns.current_user
      current_company = socket.assigns.current_company

      if current_user && current_company do
        RecentSearches.record_search(current_user.id, current_company.id, query, filters)
      end

      socket
      |> assign(:results, results)
      |> assign(:total_count, total_count)
      |> assign_search_command()
    end
  end

  defp assign_search_command(socket) do
    assign(socket, :search_command, build_search_command(socket))
  end

  defp build_search_command(socket) do
    results = socket.assigns.results
    total_count = socket.assigns.total_count
    query = socket.assigns.query
    filters = socket.assigns.filters
    active_tab = socket.assigns.active_tab
    top_result = top_search_result(results)
    result_mix = result_mix(socket, results)

    %{
      summary: search_command_summary(query, total_count, filters, top_result),
      top_result: top_result,
      actions: search_command_actions(socket, total_count, active_tab, top_result, result_mix)
    }
  end

  defp empty_search_command(filters) do
    %{
      summary: search_command_summary("", 0, filters, nil),
      top_result: nil,
      actions: starter_search_actions()
    }
  end

  defp empty_results, do: %{issues: [], agents: [], projects: [], goals: []}

  defp default_filters do
    %{
      "status" => "",
      "agent_status" => "",
      "project_status" => "",
      "goal_status" => "",
      "goal_priority" => "",
      "role" => "",
      "assignee_id" => "",
      "label_id" => "",
      "project_id" => "",
      "goal_id" => "",
      "date_from" => "",
      "date_to" => ""
    }
  end

  defp filters_from_params(params) do
    Map.new(default_filters(), fn {key, _value} -> {key, params[key] || ""} end)
  end

  defp build_url(socket, overrides) do
    base_params = %{
      "q" => socket.assigns.query,
      "tab" => to_string(socket.assigns.active_tab)
    }

    filter_params =
      socket.assigns.filters
      |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
      |> Enum.into(%{})

    all_params = Map.merge(base_params, filter_params)
    all_params = Map.merge(all_params, overrides)

    all_params
    |> Enum.reject(fn {_k, v} -> v in ["", nil] end)
    |> Enum.into(%{})
    |> then(fn params -> ~p"/search?#{params}" end)
  end

  defp result_mix(socket, results) do
    [
      {:issues, "Tasks", length(results.issues)},
      {:agents, "Agents", length(results.agents)},
      {:projects, "Projects", length(results.projects)},
      {:goals, "Goals", length(results.goals)}
    ]
    |> Enum.map(fn {key, label, count} ->
      %{key: key, label: label, count: count, url: build_url(socket, %{"tab" => to_string(key)})}
    end)
  end

  defp top_search_result(%{issues: [issue | _]}) do
    %{
      kind: "Task",
      title: issue.title,
      subtitle: issue_result_subtitle(issue),
      url: ~p"/issues/#{issue.id}"
    }
  end

  defp top_search_result(%{agents: [agent | _]}) do
    %{
      kind: "Agent",
      title: agent.name,
      subtitle:
        [Agent.role_label(agent.role), format_search_value(agent.status)] |> compact_join(" / "),
      url: ~p"/agents/#{agent.id}"
    }
  end

  defp top_search_result(%{projects: [project | _]}) do
    %{
      kind: "Project",
      title: project.name,
      subtitle: [project.prefix, format_search_value(project.status)] |> compact_join(" / "),
      url: ~p"/projects/#{project.id}"
    }
  end

  defp top_search_result(%{goals: [goal | _]}) do
    %{
      kind: "Goal",
      title: goal.title,
      subtitle:
        [format_search_value(goal.status), format_search_value(goal.priority)]
        |> compact_join(" / "),
      url: ~p"/goals/#{goal.id}"
    }
  end

  defp top_search_result(_results), do: nil

  defp issue_result_subtitle(issue) do
    [issue.identifier, format_search_value(issue.status), assignee_name(issue)]
    |> compact_join(" / ")
  end

  defp assignee_name(%{assignee: %{name: name}}) when is_binary(name) and name != "",
    do: "Assigned to #{name}"

  defp assignee_name(_issue), do: nil

  defp search_command_summary("", _total_count, _filters, _top_result),
    do: "Ready for scoped company search."

  defp search_command_summary(_query, 0, filters, _top_result) do
    if filters_active?(filters) do
      "No matches under the current filters."
    else
      "No matches in this company."
    end
  end

  defp search_command_summary(_query, total_count, filters, top_result) do
    filter_note =
      if filters_active?(filters),
        do: "#{filter_count(filters)} filters active.",
        else: "No filters active."

    "#{total_count} total matches. Top match: #{top_result.kind}. #{filter_note}"
  end

  defp search_command_actions(socket, total_count, active_tab, top_result, result_mix) do
    clear_url = ~p"/search?#{%{"q" => socket.assigns.query, "tab" => to_string(active_tab)}}"

    cond do
      socket.assigns.query in ["", nil] ->
        starter_search_actions()

      total_count == 0 and filters_active?(socket.assigns.filters) ->
        [action("Clear filters", clear_url), new_task_action(), action("Tasks", ~p"/issues")]

      total_count == 0 ->
        [new_task_action(), action("Tasks", ~p"/issues"), action("Board", ~p"/kanban")]

      true ->
        [
          action("Open top result", top_result.url),
          dominant_result_action(result_mix, active_tab),
          maybe_clear_filters_action(socket, clear_url)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.take(3)
    end
  end

  # Operations is an Advanced-only page (v7 §7): its link carries `advanced`.
  defp starter_search_actions do
    [
      new_task_action(),
      action("Board", ~p"/kanban"),
      %{action("Operations", ~p"/operations") | advanced: true}
    ]
  end

  defp new_task_action, do: action("New task", ~p"/issues/new")

  defp action(label, url), do: %{label: label, url: url, advanced: false}

  defp maybe_clear_filters_action(socket, clear_url) do
    if filters_active?(socket.assigns.filters) do
      action("Clear filters", clear_url)
    end
  end

  defp dominant_result_action(result_mix, active_tab) do
    result_mix
    |> Enum.reject(&(&1.count == 0))
    |> Enum.max_by(& &1.count, fn -> nil end)
    |> case do
      nil ->
        nil

      %{key: ^active_tab} ->
        nil

      %{label: label, url: url} ->
        action("Focus #{String.downcase(label)}", url)
    end
  end

  defp compact_join(values, separator) do
    values
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(separator)
  end

  defp format_search_value(nil), do: nil
  defp format_search_value(""), do: nil

  defp format_search_value(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp tab_count(_results, :all, total_count), do: total_count
  defp tab_count(results, tab, _total_count), do: length(Map.fetch!(results, tab))

  defp tab_label(:all), do: "All"
  defp tab_label(:issues), do: "Tasks"
  defp tab_label(:agents), do: "Agents"
  defp tab_label(:projects), do: "Projects"
  defp tab_label(:goals), do: "Goals"

  # The results a tab lists of one kind: All lists every kind, in this order.
  defp tab_items(results, active_tab, kind) when active_tab in [:all, kind],
    do: Map.fetch!(results, kind)

  defp tab_items(_results, _active_tab, _kind), do: []

  defp tab_empty?(_results, :all), do: false
  defp tab_empty?(results, tab), do: Map.fetch!(results, tab) == []

  defp result_heading(results, total_count, active_tab, query) do
    count = active_result_count(results, total_count, active_tab)
    label = active_result_label(active_tab, count)

    ~s(#{count} #{label} for "#{query}")
  end

  defp active_result_count(_results, total_count, :all), do: total_count

  defp active_result_count(results, total_count, active_tab),
    do: tab_count(results, active_tab, total_count)

  defp active_result_label(:all, 1), do: "match"
  defp active_result_label(:all, _count), do: "matches"
  defp active_result_label(:issues, 1), do: "task match"
  defp active_result_label(:issues, _count), do: "task matches"
  defp active_result_label(:agents, 1), do: "agent match"
  defp active_result_label(:agents, _count), do: "agent matches"
  defp active_result_label(:projects, 1), do: "project match"
  defp active_result_label(:projects, _count), do: "project matches"
  defp active_result_label(:goals, 1), do: "goal match"
  defp active_result_label(:goals, _count), do: "goal matches"

  defp result_empty_state("", _total_count, _filters, actions) do
    %{
      title: "Search is ready",
      detail: "Jump to current work, open the board, or create the next task from here.",
      actions: actions
    }
  end

  defp result_empty_state(query, 0, filters, actions) do
    if filters_active?(filters) do
      %{
        title: "No matches inside these filters",
        detail: "The query exists, but the active filters exclude every matching item.",
        actions: actions
      }
    else
      %{
        title: ~s(No company work matches "#{query}"),
        detail:
          "Create a new task if this is new work, or open the board to inspect active queues.",
        actions: actions
      }
    end
  end

  defp result_empty_state(_query, _total_count, _filters, _actions), do: nil

  defp parse_tab(tab) when tab in ~w(all issues agents projects goals),
    do: String.to_existing_atom(tab)

  defp parse_tab(_), do: :all

  # A task's state in the owner's words (the Task page's).
  @task_states %{
    backlog: "Later",
    todo: "To do",
    in_progress: "Working",
    in_review: "In review",
    blocked: "Blocked",
    done: "Done",
    cancelled: "Cancelled"
  }
  defp task_state(status), do: Map.get(@task_states, status) || format_search_value(status)

  # A task's goal and labels (Advanced, as their filters are): one line of plain text,
  # so its ellipsis clips text and not boxes.
  defp task_context(issue) do
    goal = issue.goal && "Goal: #{issue.goal.title}"
    labels = issue.labels != [] && "Labels: #{Enum.map_join(issue.labels, ", ", & &1.name)}"

    case Enum.filter([goal, labels], & &1) do
      [] -> nil
      parts -> Enum.join(parts, " · ")
    end
  end

  # A goal's priority is a string; Tasks.priority/1 draws the High and Critical atoms only.
  defp goal_priority("critical"), do: :critical
  defp goal_priority("high"), do: :high
  defp goal_priority(_priority), do: nil

  # Parts.status/2 (frozen, shared with Team) reads :sleeping as Idle; the heartbeat
  # skips a sleeping agent (agent_heartbeat.ex), so it is named, in Parts' shape for Offline.
  defp agent_status(%{status: :sleeping}), do: {:idle, "Sleeping"}
  defp agent_status(agent), do: CymphoWeb.AgentLive.Parts.status(agent, false)

  defp agent_line(%{title: title}) when is_binary(title) and title != "", do: title
  defp agent_line(agent), do: Agent.role_label(agent.role)

  attr :result, :map, required: true

  # One line, so the underline ends with the title (a formatted multi-line link renders a trailing space).
  defp top_link(assigns) do
    ~H"""
    <.link class="ul" navigate={@result.url}>{@result.title}</.link>
    """
  end

  defp snippet(text) when is_binary(text) and text != "" do
    if String.length(text) > 90, do: String.slice(text, 0, 90) <> "…", else: text
  end

  defp snippet(_text), do: nil

  defp filters_active?(filters) do
    Enum.any?(filters, fn {_key, value} -> value not in ["", nil] end)
  end

  defp filter_count(filters) do
    Enum.count(filters, fn {_key, value} -> value not in ["", nil] end)
  end

  defp advanced_filters_active?(filters), do: advanced_filter_count(filters) > 0

  defp advanced_filter_count(filters) do
    Enum.count(@advanced_filter_keys, fn key -> Map.get(filters, key) not in ["", nil] end)
  end

  defp recent_searches_for_user(nil), do: []
  defp recent_searches_for_user(user), do: RecentSearches.list_recent_searches(user.id)

  defp list_agents_scoped(nil), do: []
  defp list_agents_scoped(company_id), do: Agents.list_agents_by_company(company_id)

  defp list_projects_scoped(nil), do: []
  defp list_projects_scoped(company_id), do: Projects.list_projects_by_company(company_id)

  defp list_goals_scoped(nil), do: []
  defp list_goals_scoped(company_id), do: Goals.list_goals_by_company(company_id)

  defp list_labels_scoped(nil), do: []
  defp list_labels_scoped(company_id), do: Labels.list_labels_by_company(company_id)

  defp role_options do
    Agent.role_options()
    |> Enum.map(&{Agent.role_label(&1), Atom.to_string(&1)})
  end
end
