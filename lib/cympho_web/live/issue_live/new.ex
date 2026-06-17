defmodule CymphoWeb.IssueLive.New do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.Issues.Swarm
  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.IssueBriefReadiness
  alias Cympho.Orchestrator.Dispatcher
  alias Cympho.Proxies
  alias Cympho.Projects
  alias CymphoWeb.IssueLive.Components.SwarmConfig

  import CymphoWeb.IssueLive.Components.SwarmConfig, only: [swarm_configuration: 1]

  @default_attrs %{"status" => "todo", "priority" => "medium"}

  @impl true
  def mount(params, _session, socket) do
    projects = list_projects(socket)
    goals = list_goals(socket)
    scope = issue_scope(socket, params, projects, goals)
    changeset = Issues.change_issue(%Issue{}, Map.merge(@default_attrs, scope))
    swarm_params = default_swarm_params()
    swarm_config = normalize_swarm_config(socket, swarm_params)

    {:ok,
     socket
     |> assign(:page_title, "New Issue")
     |> assign(:projects, projects)
     |> assign(:goals, goals)
     |> assign(:description_placeholder, description_placeholder())
     |> assign(:launch_packet_steps, launch_packet_steps())
     |> assign(:brief_readiness, IssueBriefReadiness.evaluate(%{}))
     |> assign(:issue_params, %{})
     |> assign(:issue_scope, scope)
     |> assign(:intake_route, intake_route(scope, socket.assigns[:current_company]))
     |> assign(:runtime_enabled?, Dispatcher.enabled?())
     |> assign(:swarm_admin?, swarm_admin?(socket))
     |> assign(:proxy_profiles, proxy_profiles(socket))
     |> assign(:swarm_params, swarm_params)
     |> assign(:swarm_config, swarm_config)
     |> assign(:queue_dispatch_focus?, queue_dispatch_focus_default(scope))
     |> assign(:form, to_form(changeset))}
  end

  @impl true
  def handle_event("validate", %{"issue" => issue_params} = params, socket) do
    issue_params = normalize_issue_params(socket, issue_params)
    swarm_params = normalize_swarm_params(socket, params["swarm"])
    swarm_config = normalize_swarm_config(socket, swarm_params)
    brief_readiness = IssueBriefReadiness.evaluate(issue_params)

    changeset =
      %Issue{}
      |> Issues.change_issue(
        @default_attrs
        |> Map.merge(socket.assigns.issue_scope)
        |> Map.merge(issue_params)
      )
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(
       :queue_dispatch_focus?,
       queue_dispatch_focus_preference(socket, params, brief_readiness, swarm_config)
     )
     |> assign(:issue_params, issue_params)
     |> assign(:swarm_params, swarm_params)
     |> assign(:swarm_config, swarm_config)
     |> assign(:brief_readiness, brief_readiness)
     |> assign(form: to_form(changeset))}
  end

  @impl true
  def handle_event("use_launch_scaffold", _params, socket) do
    issue_params =
      socket.assigns
      |> Map.get(:issue_params, %{})
      |> Map.put("description", socket.assigns.brief_readiness.launch_scaffold)

    changeset =
      %Issue{}
      |> Issues.change_issue(
        @default_attrs
        |> Map.merge(socket.assigns.issue_scope)
        |> Map.merge(issue_params)
      )
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:issue_params, issue_params)
     |> assign(:brief_readiness, IssueBriefReadiness.evaluate(issue_params))
     |> assign(form: to_form(changeset))
     |> put_flash(
       :info,
       "Launch scaffold inserted into the description. Complete the placeholders before queueing focused dispatch."
     )}
  end

  @impl true
  def handle_event(
        "save",
        %{"issue" => _issue_params},
        %{assigns: %{current_company: nil}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "Choose a company before creating issues.")}
  end

  def handle_event("save", %{"issue" => issue_params} = params, socket) do
    swarm_params = normalize_swarm_params(socket, params["swarm"])
    swarm_config = normalize_swarm_config(socket, swarm_params)
    queue_focus? = dispatch_focus_checked?(params) and not swarm_config.enabled
    issue_params = normalize_issue_params(socket, issue_params)

    params =
      @default_attrs
      |> Map.merge(socket.assigns.issue_scope)
      |> Map.merge(issue_params)
      |> Map.put("swarm", swarm_params)

    case Issues.create_issue(params) do
      {:ok, issue} ->
        {issue, flash} = maybe_queue_dispatch_focus(issue, socket, queue_focus?)

        socket =
          case flash do
            nil -> socket
            {kind, message} -> put_flash(socket, kind, message)
          end

        {:noreply, push_navigate(socket, to: issue_created_path(issue))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:swarm_params, swarm_params)
         |> assign(:swarm_config, swarm_config)
         |> assign(form: to_form(Map.put(changeset, :action, :insert)))}
    end
  end

  def status_options do
    Issue.status_options()
    |> Enum.map(fn status -> {status_label(status), to_string(status)} end)
  end

  def priority_options do
    Issue.priority_options()
    |> Enum.map(fn priority -> {priority_label(priority), to_string(priority)} end)
  end

  defp description_placeholder do
    Enum.join(
      [
        "Goal:",
        "Context:",
        "Constraints / risks:",
        "Definition of done:",
        "CEO first output (`[owner_update]`, `[handoff]`, or `[blocked]`):",
        "Evidence to inspect after the run:"
      ],
      "\n"
    )
  end

  defp launch_packet_steps do
    [
      %{
        label: "Outcome",
        detail: "One concrete owner-visible result the CEO should optimize for."
      },
      %{
        label: "Context",
        detail: "The project, customer, repo, system, or market facts that change the answer."
      },
      %{
        label: "Risk/constraint",
        detail: "Deadlines, budgets, known risks, or boundaries the CEO must preserve."
      },
      %{
        label: "Done signal",
        detail: "The proof that lets the owner accept, delegate, or close the request."
      },
      %{
        label: "First CEO signal",
        detail:
          "Whether the first useful reply should be `[owner_update]`, `[handoff]`, or `[blocked]`."
      },
      %{
        label: "Evidence",
        detail: "The artifacts, child issues, verification, or risks the owner should inspect."
      }
    ]
  end

  def project_options(projects) do
    Enum.map(projects, &{&1.name, &1.id})
  end

  def goal_options(goals) do
    [{"No goal", ""} | Enum.map(goals, &{goal_option_label(&1), &1.id})]
  end

  defp status_label(:backlog), do: "Backlog"
  defp status_label(:todo), do: "To Do"
  defp status_label(:in_progress), do: "In Progress"
  defp status_label(:in_review), do: "In Review"
  defp status_label(:blocked), do: "Blocked"
  defp status_label(:done), do: "Done"
  defp status_label(:cancelled), do: "Cancelled"

  defp priority_label(priority) do
    priority
    |> to_string()
    |> String.capitalize()
  end

  defp issue_scope(socket, params, projects, goals) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        goal = selected_goal(params["goal_id"], goals)
        project_id = selected_project_id(params["project_id"], projects, goal)

        attrs =
          %{"company_id" => company_id, "project_id" => project_id}
          |> maybe_put_goal(goal)
          |> route_owner_request_to_ceo(company_id)

        case socket.assigns[:current_user] do
          %{id: user_id} -> Map.put(attrs, "created_by_user_id", user_id)
          _ -> attrs
        end

      _ ->
        %{}
    end
  end

  defp list_projects(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Projects.list_projects_by_company(company_id)
      _ -> []
    end
  end

  defp list_goals(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Goals.list_for_sidebar(company_id)
      _ -> []
    end
  end

  defp selected_project_id(_project_id, _projects, %{project_id: project_id})
       when is_binary(project_id),
       do: project_id

  defp selected_project_id(project_id, projects, _goal) when is_binary(project_id) do
    if Enum.any?(projects, &(&1.id == project_id)) do
      project_id
    else
      selected_project_id(nil, projects, nil)
    end
  end

  defp selected_project_id(_project_id, [project | _projects], _goal), do: project.id
  defp selected_project_id(_project_id, [], _goal), do: nil

  defp selected_goal(goal_id, goals) when is_binary(goal_id) and goal_id != "" do
    Enum.find(goals, &(&1.id == goal_id))
  end

  defp selected_goal("", _goals), do: nil
  defp selected_goal(nil, [goal]), do: goal
  defp selected_goal(_goal_id, _goals), do: nil

  defp maybe_put_goal(attrs, %{id: goal_id}), do: Map.put(attrs, "goal_id", goal_id)
  defp maybe_put_goal(attrs, _goal), do: attrs

  defp normalize_issue_params(socket, issue_params) do
    goal = selected_goal(issue_params["goal_id"], socket.assigns.goals)

    issue_params
    |> normalize_goal_id(goal)
    |> normalize_project_id_for_goal(goal)
  end

  defp normalize_goal_id(issue_params, %{id: goal_id}),
    do: Map.put(issue_params, "goal_id", goal_id)

  defp normalize_goal_id(issue_params, _goal), do: Map.put(issue_params, "goal_id", "")

  defp normalize_project_id_for_goal(issue_params, %{project_id: project_id})
       when is_binary(project_id) do
    Map.put(issue_params, "project_id", project_id)
  end

  defp normalize_project_id_for_goal(issue_params, _goal), do: issue_params

  defp selected_goal_context(%Phoenix.HTML.Form{} = form, goals) do
    goal_id = Phoenix.HTML.Form.input_value(form, :goal_id)
    selected_goal(goal_id, goals)
  end

  defp goal_option_label(%{goal_type: goal_type, title: title}) do
    "#{goal_type_label(goal_type)}: #{title}"
  end

  defp goal_type_label(:mission), do: "Mission"
  defp goal_type_label(:initiative), do: "Initiative"
  defp goal_type_label(:milestone), do: "Milestone"
  defp goal_type_label(goal_type), do: goal_type |> to_string() |> String.capitalize()

  defp route_owner_request_to_ceo(attrs, company_id) do
    attrs = Map.put(attrs, "assigned_role", "ceo")

    case Agents.get_company_ceo(company_id) do
      {:ok, ceo} -> Map.put(attrs, "assignee_id", ceo.id)
      {:error, :not_found} -> attrs
    end
  end

  defp intake_route(%{"assignee_id" => agent_id, "assigned_role" => role}, %{id: company_id}) do
    case Agents.get_company_agent(company_id, agent_id) do
      {:ok, agent} -> %{agent: agent, role: role}
      {:error, _} -> nil
    end
  end

  defp intake_route(%{"assigned_role" => "ceo"}, %{id: _company_id}) do
    %{agent: nil, role: "ceo", missing?: true}
  end

  defp intake_route(_scope, _company), do: nil

  defp queue_dispatch_focus_default(%{"assigned_role" => "ceo", "assignee_id" => assignee_id})
       when is_binary(assignee_id),
       do: true

  defp queue_dispatch_focus_default(_scope), do: false

  defp dispatch_focus_checked?(%{"queue_dispatch_focus" => value})
       when value in ["true", "on", "1", true],
       do: true

  defp dispatch_focus_checked?(%{"queue_dispatch_focus" => values}) when is_list(values) do
    Enum.any?(values, &(&1 in ["true", "on", "1", true]))
  end

  defp dispatch_focus_checked?(_params), do: false

  defp queue_dispatch_focus_preference(_socket, _params, _readiness, %{enabled: true}), do: false

  defp queue_dispatch_focus_preference(socket, params, %{status: :ready}, _swarm_config) do
    if socket.assigns.brief_readiness.status == :ready do
      dispatch_focus_checked?(params)
    else
      socket.assigns[:queue_dispatch_focus?] || false
    end
  end

  defp queue_dispatch_focus_preference(socket, _params, _readiness, _swarm_config) do
    socket.assigns[:queue_dispatch_focus?] || false
  end

  defp queue_focus_checked?(%{status: :ready}, queue_focus?), do: queue_focus?
  defp queue_focus_checked?(_readiness, _queue_focus?), do: false

  defp queue_focus_disabled?(%{status: :ready}), do: false
  defp queue_focus_disabled?(_readiness), do: true

  defp queue_focus_control_class(%{status: :ready}) do
    "border-sky-500/25 bg-sky-500/[0.07] text-sky-100"
  end

  defp queue_focus_control_class(_readiness) do
    "border-border bg-panel/70 text-text-tertiary"
  end

  defp queue_focus_label(%{status: :ready}), do: "Queue focused CEO run after create"

  defp queue_focus_label(_readiness), do: "Focused CEO run needs a ready brief"

  defp queue_focus_label(_readiness, %{enabled: true}), do: "CEO run waits for swarm synthesis"

  defp queue_focus_label(readiness, _swarm_config), do: queue_focus_label(readiness)

  defp queue_focus_detail(%{status: :ready}) do
    "Pins this new issue for the next focused runtime pass. The issue page will show the exact command to start the first CEO turn on port 4329."
  end

  defp queue_focus_detail(%{next_prompt: next_prompt}) do
    "Create a draft now, or add the missing signal first: #{next_prompt}"
  end

  defp queue_focus_detail(_readiness, %{enabled: true}) do
    "Swarm mode blocks the CEO parent on temporary worker delivery and CTO synthesis before CEO runtime resumes."
  end

  defp queue_focus_detail(readiness, _swarm_config), do: queue_focus_detail(readiness)

  defp create_launch_state(_readiness, _queue_focus?, _intake_route, %{enabled: true}) do
    %{
      tone: :ready,
      label: "Ready to create swarm",
      badge: "Swarm",
      detail:
        "Save will create the CEO parent, launch temporary non-engineering workers, and route synthesis through CTO before CEO review."
    }
  end

  defp create_launch_state(readiness, queue_focus?, intake_route, _swarm_config) do
    create_launch_state(readiness, queue_focus?, intake_route)
  end

  defp create_launch_state(_readiness, _queue_focus?, %{missing?: true}) do
    %{
      tone: :attention,
      label: "CEO setup needed",
      badge: "Setup",
      detail:
        "Save will create a CEO-lane issue, but runtime cannot start until a CEO agent exists."
    }
  end

  defp create_launch_state(%{status: :ready}, true, _intake_route) do
    %{
      tone: :ready,
      label: "Ready to create and queue",
      badge: "Queued",
      detail: "Save will create the CEO issue and pin it for the next focused runtime pass."
    }
  end

  defp create_launch_state(%{status: :ready}, _queue_focus?, _intake_route) do
    %{
      tone: :ready,
      label: "Ready for manual launch",
      badge: "Ready",
      detail:
        "Save will create the CEO issue. You can queue the first CEO run from the issue page."
    }
  end

  defp create_launch_state(%{next_prompt: next_prompt}, _queue_focus?, _intake_route) do
    %{
      tone: :draft,
      label: "Draft only until the brief is ready",
      badge: "Draft",
      detail:
        "Save can create the CEO issue, but focused dispatch will not queue yet. #{next_prompt}"
    }
  end

  defp launch_state_class(:ready), do: "border-success/25 bg-success/10 text-success"
  defp launch_state_class(:attention), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp launch_state_class(:draft), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"
  defp launch_state_class(_tone), do: "border-border bg-panel/70 text-text-secondary"

  defp submit_label(_readiness, _queue_focus?, %{missing?: true}), do: "Create CEO Issue"

  defp submit_label(%{status: :ready}, true, _intake_route), do: "Create and Queue CEO Run"

  defp submit_label(%{status: :ready}, _queue_focus?, _intake_route), do: "Create CEO Issue"

  defp submit_label(_readiness, _queue_focus?, _intake_route), do: "Create Draft CEO Issue"

  defp submit_label(_readiness, _queue_focus?, _intake_route, %{enabled: true}),
    do: "Create Swarm Issue"

  defp submit_label(readiness, queue_focus?, intake_route, _swarm_config),
    do: submit_label(readiness, queue_focus?, intake_route)

  defp default_swarm_params do
    %{
      "enabled" => "false",
      "agent_count" => "3",
      "mix_rows" => default_swarm_mix_rows(),
      "mix" => default_swarm_mix(),
      "proxy_mode" => "none",
      "proxy_enabled" => "false",
      "proxy_profile" => "",
      "proxy_profile_ids" => [],
      "proxy_pool" => ""
    }
  end

  defp normalize_swarm_params(socket, params) do
    if socket.assigns[:swarm_admin?] do
      normalize_swarm_params(params)
    else
      default_swarm_params()
    end
  end

  defp normalize_swarm_params(nil), do: default_swarm_params()

  defp normalize_swarm_params(params) when is_map(params) do
    default_swarm_params()
    |> Map.merge(params)
    |> Map.put("enabled", checkbox_value(params, "enabled"))
    |> Map.put("proxy_enabled", checkbox_value(params, "proxy_enabled"))
    |> Map.put("proxy_mode", normalize_proxy_mode(params["proxy_mode"]))
    |> Map.put("proxy_profile_ids", normalize_string_list(params["proxy_profile_ids"]))
    |> Map.put("mix_rows", normalize_mix_rows(params["mix_rows"]))
  end

  defp normalize_swarm_params(_params), do: default_swarm_params()

  defp checkbox_value(params, key) do
    if Map.get(params, key) in ["true", "on", "1", true], do: "true", else: "false"
  end

  defp default_swarm_mix do
    [
      "claude_code | sonnet",
      "codex | gpt-5.3-high-fast",
      "openai_chat | gpt-5.4-mini"
    ]
    |> Enum.join("\n")
  end

  defp default_swarm_mix_rows do
    SwarmConfig.default_mix_rows()
  end

  defp normalize_mix_rows(rows) when is_map(rows) do
    rows = Map.new(rows, fn {index, row} -> {to_string(index), row} end)

    rows
    |> Map.new(fn {index, row} ->
      row = row || %{}

      {index,
       %{
         "enabled" => checkbox_value(row, "enabled"),
         "harness" => row["harness"] || "openai_chat",
         "model" => row["model"] || "",
         "reasoning_effort" => normalize_reasoning_effort(row["reasoning_effort"])
       }}
    end)
    |> then(fn normalized ->
      if map_size(normalized) == 0, do: default_swarm_mix_rows(), else: normalized
    end)
  end

  defp normalize_mix_rows(_rows), do: default_swarm_mix_rows()

  defp normalize_proxy_mode(mode) when mode in ["none", "manual", "random", "selected"], do: mode
  defp normalize_proxy_mode(_mode), do: "none"

  defp normalize_reasoning_effort(effort) when effort in ["auto", "low", "medium", "high"],
    do: effort

  defp normalize_reasoning_effort(_effort), do: "auto"

  defp normalize_string_list(values) when is_list(values) do
    values
    |> Enum.filter(&is_binary/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp normalize_string_list(value) when is_binary(value) and value != "", do: [value]
  defp normalize_string_list(_values), do: []

  defp swarm_enabled?(%{enabled: enabled}), do: enabled
  defp swarm_enabled?(_), do: false

  defp swarm_count(%{agent_count: count}), do: count
  defp swarm_count(_), do: 0

  defp swarm_admin?(%{
         assigns: %{current_user: %{id: user_id}, current_company: %{id: company_id}}
       }) do
    Companies.admin?(user_id, company_id) or Companies.is_board_member?(user_id, company_id)
  end

  defp swarm_admin?(_socket), do: false

  defp normalize_swarm_config(socket, swarm_params) do
    Swarm.normalize_config(%{
      "swarm" => swarm_params,
      "company_id" => socket.assigns[:current_company] && socket.assigns.current_company.id
    })
  end

  defp proxy_profiles(%{assigns: %{current_company: %{id: company_id}}}) do
    Proxies.list_proxy_profiles(company_id)
  end

  defp proxy_profiles(_socket), do: []

  defp issue_created_path(issue) do
    path = ~p"/issues/#{issue.id}"

    if Issues.dispatch_pinned?(issue) and issue.assigned_role == "ceo" do
      path <> "#issue-ceo-flow-checklist"
    else
      path
    end
  end

  defp maybe_queue_dispatch_focus(issue, socket, true) do
    readiness = IssueBriefReadiness.evaluate(issue)

    if readiness.status == :ready do
      case Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
        {:ok, focused_issue} ->
          {focused_issue,
           {:info,
            "CEO issue created and queued for focused dispatch. Copy the focused runtime command on the issue page to start the first CEO turn."}}

        {:error, _reason} ->
          {issue,
           {:error,
            "Issue created, but dispatch focus could not be queued. Open the issue and queue focus from the CEO flow checklist."}}
      end
    else
      {issue,
       {:error,
        "CEO issue created, but focused dispatch was not queued because the owner brief is not launch-ready. #{readiness.next_prompt}"}}
    end
  end

  defp maybe_queue_dispatch_focus(issue, _socket, _queue_focus?), do: {issue, nil}
end
