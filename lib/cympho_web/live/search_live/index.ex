defmodule CymphoWeb.SearchLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Search
  alias Cympho.RecentSearches
  alias Cympho.Agents
  alias Cympho.Projects
  alias Cympho.Labels

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, "Search")
      |> assign(:query, "")
      |> assign(:results, %{issues: [], agents: [], projects: [], goals: []})
      |> assign(:recent_searches, recent_searches_for_user(current_user))
      |> assign(:agents, Agents.list_agents())
      |> assign(:projects, Projects.list_projects())
      |> assign(:labels, Labels.list_labels())
      |> assign(:filters, %{
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
      })
      |> assign(:active_tab, :all)
      |> assign(:total_count, 0)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    query = params["q"] || ""
    active_tab = params["tab"] || "all"

    filters = %{
      "status" => params["status"] || "",
      "agent_status" => params["agent_status"] || "",
      "project_status" => params["project_status"] || "",
      "goal_status" => params["goal_status"] || "",
      "goal_priority" => params["goal_priority"] || "",
      "role" => params["role"] || "",
      "assignee_id" => params["assignee_id"] || "",
      "label_id" => params["label_id"] || "",
      "project_id" => params["project_id"] || "",
      "goal_id" => params["goal_id"] || "",
      "date_from" => params["date_from"] || "",
      "date_to" => params["date_to"] || ""
    }

    socket =
      socket
      |> assign(:query, query)
      |> assign(:filters, filters)
      |> assign(:active_tab, String.to_existing_atom(active_tab))
      |> perform_search()
      |> assign(:recent_searches, RecentSearches.list_recent_searches(socket.assigns.current_user.id))

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
         build_url(socket,
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
     push_patch(socket, to: ~p"/search?q=#{socket.assigns.query}&tab=#{socket.assigns.active_tab}")}
  end

  def handle_event("recent_search", %{"query" => query}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/search?q=#{query}&tab=#{socket.assigns.active_tab}")}
  end

  def handle_event("clear_recent_searches", _params, socket) do
    current_user = socket.assigns.current_user
    RecentSearches.clear_recent_searches(current_user.id)

    {:noreply,
     socket
     |> assign(:recent_searches, [])}
  end

  defp perform_search(socket) do
    query = socket.assigns.query
    filters = socket.assigns.filters

    if String.trim(query) == "" do
      socket
      |> assign(:results, %{issues: [], agents: [], projects: [], goals: []})
      |> assign(:total_count, 0)
    else
      results = Search.search_all(query, filters, limit: 20)
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
    end
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

  defp tab_count(_results, :all), do: nil

  defp tab_count(results, tab) do
    case tab do
      :issues -> length(results.issues)
      :agents -> length(results.agents)
      :projects -> length(results.projects)
      :goals -> length(results.goals)
    end
  end

  defp active_tab?(socket, tab), do: socket.assigns.active_tab == tab

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:done), do: "Done"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(:active), do: "Active"
  defp status_label(:archived), do: "Archived"
  defp status_label(:completed), do: "Completed"
  defp status_label(:idle), do: "Idle"
  defp status_label(:running), do: "Running"
  defp status_label(:error), do: "Error"
  defp status_label(:sleeping), do: "Sleeping"
  defp status_label(:offline), do: "Offline"
  defp status_label(other), do: String.capitalize(to_string(other))

  defp status_color(:backlog), do: "bg-gray-100 text-gray-800"
  defp status_color(:todo), do: "bg-blue-100 text-blue-800"
  defp status_color(:in_progress), do: "bg-yellow-100 text-yellow-800"
  defp status_color(:in_review), do: "bg-purple-100 text-purple-800"
  defp status_color(:done), do: "bg-green-100 text-green-800"
  defp status_color(:blocked), do: "bg-red-100 text-red-800"
  defp status_color(:cancelled), do: "bg-gray-100 text-gray-800"
  defp status_color(:active), do: "bg-green-100 text-green-800"
  defp status_color(:archived), do: "bg-gray-100 text-gray-800"
  defp status_color(:completed), do: "bg-green-100 text-green-800"
  defp status_color(:idle), do: "bg-gray-100 text-gray-800"
  defp status_color(:running), do: "bg-green-100 text-green-800"
  defp status_color(:error), do: "bg-red-100 text-red-800"
  defp status_color(:sleeping), do: "bg-yellow-100 text-yellow-800"
  defp status_color(:offline), do: "bg-gray-100 text-gray-800"
  defp status_color(_), do: "bg-gray-100 text-gray-800"

  defp priority_label(:low), do: "Low"
  defp priority_label(:medium), do: "Medium"
  defp priority_label(:high), do: "High"
  defp priority_label(:critical), do: "Critical"
  defp priority_label(other), do: String.capitalize(to_string(other))

  defp priority_color(:low), do: "text-gray-600"
  defp priority_color(:medium), do: "text-blue-600"
  defp priority_color(:high), do: "text-orange-600"
  defp priority_color(:critical), do: "text-red-600"
  defp priority_color(_), do: "text-gray-600"

  defp agent_status_color(:idle), do: "#6B7280"
  defp agent_status_color(:running), do: "#10B981"
  defp agent_status_color(:error), do: "#EF4444"
  defp agent_status_color(:sleeping), do: "#F59E0B"
  defp agent_status_color(:offline), do: "#374151"
  defp agent_status_color(_), do: "#6B7280"

  defp filters_active?(filters) do
    filters["status"] != "" or
      filters["assignee_id"] != "" or
      filters["label_id"] != "" or
      filters["project_id"] != "" or
      filters["date_from"] != "" or
      filters["date_to"] != ""
  end

  defp recent_searches_for_user(nil), do: []
  defp recent_searches_for_user(user), do: RecentSearches.list_recent_searches(user.id)
end
