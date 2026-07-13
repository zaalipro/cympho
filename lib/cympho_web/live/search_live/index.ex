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
      |> assign(:labels, Labels.list_labels())
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
      active: String.trim(query) != "",
      result_mix: result_mix,
      summary: search_command_summary(query, total_count, filters, top_result),
      top_result: top_result,
      actions: search_command_actions(socket, total_count, active_tab, top_result, result_mix)
    }
  end

  defp empty_search_command(filters) do
    %{
      active: false,
      result_mix: [
        %{key: :issues, label: "Issues", count: 0, url: ~p"/search?tab=issues"},
        %{key: :agents, label: "Agents", count: 0, url: ~p"/search?tab=agents"},
        %{key: :projects, label: "Projects", count: 0, url: ~p"/search?tab=projects"},
        %{key: :goals, label: "Goals", count: 0, url: ~p"/search?tab=goals"}
      ],
      summary: search_command_summary("", 0, filters, nil),
      top_result: nil,
      actions: [
        %{label: "New issue", url: ~p"/issues/new", tone: :primary, icon: "hero-plus-mini"},
        %{label: "Board", url: ~p"/kanban", tone: :neutral, icon: "hero-view-columns-mini"},
        %{
          label: "Operations",
          url: ~p"/operations",
          tone: :neutral,
          icon: "hero-command-line-mini"
        }
      ]
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
      {:issues, "Issues", length(results.issues)},
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
      kind: "Issue",
      title: issue.title,
      subtitle: issue_result_subtitle(issue),
      url: ~p"/issues/#{issue.id}",
      icon: "hero-document-text-mini"
    }
  end

  defp top_search_result(%{agents: [agent | _]}) do
    %{
      kind: "Agent",
      title: agent.name,
      subtitle:
        [Agent.role_label(agent.role), format_search_value(agent.status)] |> compact_join(" / "),
      url: ~p"/agents/#{agent.id}",
      icon: "hero-sparkles-mini"
    }
  end

  defp top_search_result(%{projects: [project | _]}) do
    %{
      kind: "Project",
      title: project.name,
      subtitle: [project.prefix, format_search_value(project.status)] |> compact_join(" / "),
      url: ~p"/projects/#{project.id}",
      icon: "hero-folder-mini"
    }
  end

  defp top_search_result(%{goals: [goal | _]}) do
    %{
      kind: "Goal",
      title: goal.title,
      subtitle:
        [format_search_value(goal.status), format_search_value(goal.priority)]
        |> compact_join(" / "),
      url: ~p"/goals/#{goal.id}",
      icon: "hero-flag-mini"
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
        [
          %{label: "Clear filters", url: clear_url, tone: :primary, icon: "hero-x-mark-mini"},
          %{label: "New issue", url: ~p"/issues/new", tone: :neutral, icon: "hero-plus-mini"},
          %{label: "Issues", url: ~p"/issues", tone: :neutral, icon: "hero-document-text-mini"}
        ]

      total_count == 0 ->
        [
          %{label: "New issue", url: ~p"/issues/new", tone: :primary, icon: "hero-plus-mini"},
          %{label: "Issues", url: ~p"/issues", tone: :neutral, icon: "hero-document-text-mini"},
          %{label: "Board", url: ~p"/kanban", tone: :neutral, icon: "hero-view-columns-mini"}
        ]

      true ->
        [
          %{label: "Open top result", url: top_result.url, tone: :primary, icon: top_result.icon},
          dominant_result_action(result_mix, active_tab),
          maybe_clear_filters_action(socket, clear_url)
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.take(3)
    end
  end

  defp starter_search_actions do
    [
      %{label: "New issue", url: ~p"/issues/new", tone: :primary, icon: "hero-plus-mini"},
      %{label: "Board", url: ~p"/kanban", tone: :neutral, icon: "hero-view-columns-mini"},
      %{label: "Operations", url: ~p"/operations", tone: :neutral, icon: "hero-command-line-mini"}
    ]
  end

  defp maybe_clear_filters_action(socket, clear_url) do
    if filters_active?(socket.assigns.filters) do
      %{label: "Clear filters", url: clear_url, tone: :neutral, icon: "hero-x-mark-mini"}
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
        %{
          label: "Focus #{String.downcase(label)}",
          url: url,
          tone: :neutral,
          icon: "hero-funnel-mini"
        }
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

  defp search_command_action_class(:primary) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg bg-primary px-3 text-sm font-510 text-white transition-colors hover:bg-primary-hover"
  end

  defp search_command_action_class(_tone) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-border bg-surface px-3 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end

  defp search_mix_card_class(count) when count > 0 do
    "flex min-h-24 min-w-0 flex-col justify-between rounded-lg border border-primary/25 bg-primary/10 px-4 py-3 text-left transition-colors hover:border-primary/40 hover:bg-primary/15"
  end

  defp search_mix_card_class(_count) do
    "flex min-h-24 min-w-0 flex-col justify-between rounded-lg border border-border bg-surface-1 px-4 py-3 text-left transition-colors hover:bg-surface-2"
  end

  defp search_mix_count_class(count) when count > 0,
    do: "mt-4 font-mono text-2xl font-590 text-primary"

  defp search_mix_count_class(_count),
    do: "mt-4 font-mono text-2xl font-590 text-text-quaternary"

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

  defp result_empty_state("", _total_count, _filters, actions) do
    %{
      icon: "hero-magnifying-glass-mini",
      title: "Search is ready",
      detail: "Jump to current work, open the board, or create the next issue from here.",
      actions: actions
    }
  end

  defp result_empty_state(query, 0, filters, actions) do
    if filters_active?(filters) do
      %{
        icon: "hero-funnel-mini",
        title: "No matches inside these filters",
        detail: "The query exists, but the active filters exclude every matching item.",
        actions: actions
      }
    else
      %{
        icon: "hero-magnifying-glass-mini",
        title: ~s(No company work matches "#{query}"),
        detail:
          "Create a new issue if this is new work, or open the board to inspect active queues.",
        actions: actions
      }
    end
  end

  defp result_empty_state(_query, _total_count, _filters, _actions), do: nil

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

  defp role_options do
    Agent.role_options()
    |> Enum.map(&{Agent.role_label(&1), Atom.to_string(&1)})
  end

  defp render_issues(assigns, issues, title) do
    assigns = assign(assigns, issues: issues, section_title: title)

    ~H"""
    <div :if={@issues != []} class="space-y-2">
      <div :if={@section_title} class="mb-3 flex items-center gap-2">
        <.icon name="hero-document-text-mini" class="h-4 w-4 text-text-quaternary" />
        <h2 class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
          {@section_title}
        </h2>
        <span class="font-mono text-xs text-text-quaternary">{length(@issues)}</span>
      </div>
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
      <div :if={@section_title} class="mb-3 flex items-center gap-2">
        <.icon name="hero-sparkles-mini" class="h-4 w-4 text-text-quaternary" />
        <h2 class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
          {@section_title}
        </h2>
        <span class="font-mono text-xs text-text-quaternary">{length(@agents)}</span>
      </div>
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
      <div :if={@section_title} class="mb-3 flex items-center gap-2">
        <.icon name="hero-folder-mini" class="h-4 w-4 text-text-quaternary" />
        <h2 class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
          {@section_title}
        </h2>
        <span class="font-mono text-xs text-text-quaternary">{length(@projects)}</span>
      </div>
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
      <div :if={@section_title} class="mb-3 flex items-center gap-2">
        <.icon name="hero-flag-mini" class="h-4 w-4 text-text-quaternary" />
        <h2 class="font-serif text-[13px] font-510 italic tracking-[0.02em] text-brand/90">
          {@section_title}
        </h2>
        <span class="font-mono text-xs text-text-quaternary">{length(@goals)}</span>
      </div>
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
