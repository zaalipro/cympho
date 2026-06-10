defmodule CymphoWeb.SearchLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Search
  alias Cympho.RecentSearches
  alias Cympho.Agents
  alias Cympho.Agents.Agent
  alias Cympho.Goals
  alias Cympho.Projects
  alias Cympho.Labels

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns.current_user
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    socket =
      socket
      |> assign(:page_title, "Search")
      |> assign(:query, "")
      |> assign(:results, %{issues: [], agents: [], projects: [], goals: []})
      |> assign(:recent_searches, recent_searches_for_user(current_user))
      |> assign(:agents, list_agents_scoped(company_id))
      |> assign(:projects, list_projects_scoped(company_id))
      |> assign(:goals, list_goals_scoped(company_id))
      |> assign(:role_options, role_options())
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
    active_tab = parse_tab(params["tab"])

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
      |> assign(:results, %{issues: [], agents: [], projects: [], goals: []})
      |> assign(:total_count, 0)
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

  defp result_heading(_results, _total_count, _active_tab, ""), do: "Ready when you are"

  defp result_heading(results, total_count, active_tab, query) do
    count = active_result_count(results, total_count, active_tab)
    label = active_result_label(active_tab, count)

    ~s(#{count} #{label} for "#{query}")
  end

  defp active_result_count(_results, total_count, :all), do: total_count

  defp active_result_count(results, _total_count, active_tab),
    do: tab_count(results, active_tab) || 0

  defp active_result_label(:all, 1), do: "match"
  defp active_result_label(:all, _count), do: "matches"
  defp active_result_label(:issues, 1), do: "issue match"
  defp active_result_label(:issues, _count), do: "issue matches"
  defp active_result_label(:agents, 1), do: "agent match"
  defp active_result_label(:agents, _count), do: "agent matches"
  defp active_result_label(:projects, 1), do: "project match"
  defp active_result_label(:projects, _count), do: "project matches"
  defp active_result_label(:goals, 1), do: "goal match"
  defp active_result_label(:goals, _count), do: "goal matches"

  defp parse_tab(tab) when tab in ~w(all issues agents projects goals),
    do: String.to_existing_atom(tab)

  defp parse_tab(_), do: :all

  defp agent_status_dot_class(:running), do: "bg-emerald-400"
  defp agent_status_dot_class(:error), do: "bg-red-400"
  defp agent_status_dot_class(:sleeping), do: "bg-amber-400"
  defp agent_status_dot_class(:offline), do: "bg-text-quaternary"
  defp agent_status_dot_class(_status), do: "bg-text-tertiary"

  defp filters_active?(filters) do
    Enum.any?(filters, fn {_key, value} -> value not in ["", nil] end)
  end

  defp filter_count(filters) do
    Enum.count(filters, fn {_key, value} -> value not in ["", nil] end)
  end

  defp recent_searches_for_user(nil), do: []
  defp recent_searches_for_user(user), do: RecentSearches.list_recent_searches(user.id)

  defp list_agents_scoped(nil), do: []
  defp list_agents_scoped(company_id), do: Agents.list_agents_by_company(company_id)

  defp list_projects_scoped(nil), do: []
  defp list_projects_scoped(company_id), do: Projects.list_projects_by_company(company_id)

  defp list_goals_scoped(nil), do: []
  defp list_goals_scoped(company_id), do: Goals.list_goals_by_company(company_id)

  defp role_options do
    Agent.role_options()
    |> Enum.map(&{Agent.role_label(&1), Atom.to_string(&1)})
  end

  defp render_issues(assigns, issues, title) do
    assigns = assign(assigns, issues: issues, section_title: title)

    ~H"""
    <div :if={@issues != []} class="space-y-2">
      <h2 :if={@section_title} class="mb-3 text-card-title text-text-primary">
        {@section_title}
      </h2>
      <div class="space-y-2">
        <.app_link
          :for={issue <- @issues}
          navigate={~p"/issues/#{issue.id}"}
          class="block rounded-lg border border-border bg-surface-1 px-4 py-3 transition-colors hover:bg-surface-2"
        >
          <div class="flex min-w-0 flex-col gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <span
                :if={issue.identifier}
                class="font-mono text-xs font-510 text-text-tertiary"
              >
                {issue.identifier}
              </span>
              <.badge variant="status" value={to_string(issue.status)} />
              <.badge variant="priority" value={to_string(issue.priority)} />
            </div>
            <div class="min-w-0">
              <h3 class="truncate text-base font-590 text-text-primary">{issue.title}</h3>
              <p class="mt-1 text-sm text-text-tertiary line-clamp-2">{issue.description}</p>
            </div>
            <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-text-quaternary">
              <span :if={issue.assignee}>Assignee: {issue.assignee.name}</span>
              <span :if={issue.project}>Project: {issue.project.name}</span>
              <span :if={issue.goal}>Goal: {issue.goal.title}</span>
              <span :if={issue.labels != []}>
                Labels: {Enum.map_join(issue.labels, ", ", & &1.name)}
              </span>
            </div>
          </div>
        </.app_link>
      </div>
    </div>
    """
  end

  defp render_agents(assigns, agents, title) do
    assigns = assign(assigns, agents: agents, section_title: title)

    ~H"""
    <div :if={@agents != []} class="space-y-2">
      <h2 :if={@section_title} class="mb-3 text-card-title text-text-primary">
        {@section_title}
      </h2>
      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
        <.app_link
          :for={agent <- @agents}
          navigate={~p"/agents/#{agent.id}"}
          class="block rounded-lg border border-border bg-surface-1 px-4 py-3 transition-colors hover:bg-surface-2"
        >
          <div class="flex items-start justify-between gap-3">
            <div class="min-w-0">
              <h3 class="truncate text-base font-590 text-text-primary">{agent.name}</h3>
              <p :if={agent.title not in [nil, ""]} class="mt-1 text-sm text-text-tertiary">
                {agent.title}
              </p>
              <div class="mt-2 flex flex-wrap items-center gap-2 text-xs text-text-quaternary">
                <span>{Agent.role_label(agent.role)}</span>
                <span>/</span>
                <span class="capitalize">{agent.status}</span>
              </div>
            </div>
            <span class={[
              "mt-1 h-2.5 w-2.5 shrink-0 rounded-full",
              agent_status_dot_class(agent.status)
            ]}>
            </span>
          </div>
        </.app_link>
      </div>
    </div>
    """
  end

  defp render_projects(assigns, projects, title) do
    assigns = assign(assigns, projects: projects, section_title: title)

    ~H"""
    <div :if={@projects != []} class="space-y-2">
      <h2 :if={@section_title} class="mb-3 text-card-title text-text-primary">
        {@section_title}
      </h2>
      <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
        <.app_link
          :for={project <- @projects}
          navigate={~p"/projects/#{project.id}"}
          class="block rounded-lg border border-border bg-surface-1 px-4 py-3 transition-colors hover:bg-surface-2"
        >
          <div class="mb-2 flex flex-wrap items-center gap-2">
            <.badge variant="pill" value={project.prefix} />
            <.badge variant="status" value={to_string(project.status)} />
          </div>
          <h3 class="truncate text-base font-590 text-text-primary">{project.name}</h3>
          <p class="mt-1 text-sm text-text-tertiary line-clamp-2">{project.description}</p>
        </.app_link>
      </div>
    </div>
    """
  end

  defp render_goals(assigns, goals, title) do
    assigns = assign(assigns, goals: goals, section_title: title)

    ~H"""
    <div :if={@goals != []} class="space-y-2">
      <h2 :if={@section_title} class="mb-3 text-card-title text-text-primary">
        {@section_title}
      </h2>
      <div class="space-y-2">
        <.app_link
          :for={goal <- @goals}
          navigate={~p"/goals/#{goal.id}"}
          class="block rounded-lg border border-border bg-surface-1 px-4 py-3 transition-colors hover:bg-surface-2"
        >
          <div class="flex min-w-0 flex-col gap-2">
            <div class="flex flex-wrap items-center gap-2">
              <.badge variant="status" value={goal.status} />
              <.badge variant="priority" value={goal.priority} />
              <span class="text-xs text-text-quaternary">
                {goal.goal_type |> to_string() |> String.capitalize()}
              </span>
            </div>
            <div class="min-w-0">
              <h3 class="truncate text-base font-590 text-text-primary">{goal.title}</h3>
              <p class="mt-1 text-sm text-text-tertiary line-clamp-2">{goal.description}</p>
            </div>
            <div class="flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-text-quaternary">
              <span :if={goal.project}>Project: {goal.project.name}</span>
            </div>
          </div>
        </.app_link>
      </div>
    </div>
    """
  end
end
