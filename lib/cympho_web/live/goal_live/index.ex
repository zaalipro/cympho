defmodule CymphoWeb.GoalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Issues
  alias Cympho.Goals

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:digest_density, "compact")
      |> assign(:infinite_scroll, %{})
      |> assign_goal_overview()

    {:ok, init_stream(socket, :goals, &fetch_goals(socket, &1))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    socket
    |> assign(:page_title, "Goals")
    |> assign(:goal, nil)
    |> assign(:digest_density, normalize_digest_density(params["density"]))
    |> assign_goal_overview()
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  defp goal_index_url("detailed"), do: ~p"/goals?#{%{density: "detailed"}}"
  defp goal_index_url(_density), do: ~p"/goals"

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

  @impl true
  def handle_event("delete_goal", %{"id" => id}, socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        case Goals.get_company_goal(company_id, id) do
          {:ok, goal} ->
            {:ok, _} = Goals.delete_goal(goal)

            socket = assign_goal_overview(socket)
            {:noreply, reset_stream(socket, :goals, &fetch_goals(socket, &1))}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Goal not found")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No company selected")}
    end
  end

  def handle_event("link_issue_to_goal", %{"issue_id" => issue_id, "goal_id" => goal_id}, socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        with {:ok, issue} <- Issues.get_company_issue(company_id, issue_id),
             {:ok, goal} <- Goals.get_company_goal(company_id, goal_id),
             :ok <- active_goal?(goal),
             attrs <- issue_goal_attrs(issue, goal),
             {:ok, _issue} <- Issues.update_issue(issue, attrs) do
          socket =
            socket
            |> put_flash(:info, "Linked #{issue.identifier || "issue"} to #{goal.title}.")
            |> assign_goal_overview()

          {:noreply, reset_stream(socket, :goals, &fetch_goals(socket, &1))}
        else
          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "Issue or goal not found.")}

          {:error, :inactive_goal} ->
            {:noreply, put_flash(socket, :error, "Choose an active goal.")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not link issue to goal.")}
        end

      _ ->
        {:noreply, put_flash(socket, :error, "No company selected.")}
    end
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :goals, &fetch_goals(socket, &1))}
  end

  defp fetch_goals(socket, cursor) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Goals.list_goals_by_company_page(company_id, after: cursor)
      _ -> Goals.list_goals_page(after: cursor)
    end
  end

  defp assign_goal_overview(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} ->
        alignment_summary = Goals.alignment_summary(company_id)
        goal_work_health = Goals.goal_work_health(company_id)
        goals = Goals.list_goals_by_company(company_id)

        socket
        |> assign(:alignment_summary, alignment_summary)
        |> assign(:goal_work_health, goal_work_health)
        |> assign(:goal_link_targets, goal_link_targets(goals))
        |> assign(:goal_command, build_goal_command(alignment_summary, goal_work_health, goals))

      _ ->
        socket
        |> assign(:alignment_summary, Goals.empty_alignment_summary())
        |> assign(:goal_work_health, %{})
        |> assign(:goal_link_targets, [])
        |> assign(:goal_command, empty_goal_command())
    end
  end

  defp empty_goal_command do
    %{
      tone: :empty,
      badge: "Ready for mission",
      heading: "Create the first operating mission",
      detail:
        "Define the business outcome agents should optimize before adding more autonomous work.",
      action_label: "Create mission",
      action_path: "/goals/new",
      focus_label: nil,
      focus_detail: nil,
      aligned_percent: 0,
      floating_count: 0,
      idle_count: 0,
      blocked_goal_count: 0,
      review_goal_count: 0
    }
  end

  defp build_goal_command(summary, goal_work_health, goals) do
    active_goals = Enum.filter(goals, &(&1.status == "active"))
    blocked_goal = first_goal_with(active_goals, goal_work_health, &(&1.blocked > 0))
    review_goal = first_goal_with(active_goals, goal_work_health, &(&1.in_review > 0))
    idle_goal = first_goal_with(active_goals, goal_work_health, &(&1.open == 0))
    risk_issue = List.first(summary.risk_issues)

    command =
      cond do
        summary.active_missions == 0 ->
          %{
            tone: :attention,
            badge: "No mission",
            heading: "Create an operating mission",
            detail:
              "Agents need a mission anchor before they can optimize owner requests against a business outcome.",
            action_label: "Create mission",
            action_path: "/goals/new",
            focus_label: "Mission missing",
            focus_detail: "No active mission is available for new work."
          }

        risk_issue ->
          %{
            tone: :attention,
            badge: "Unguided work",
            heading: "Link floating work to strategy",
            detail:
              "#{risk_issue.title} is active without a goal. Attach it to a mission or intentionally cancel it.",
            action_label: "Open unlinked issue",
            action_path: "/issues/#{risk_issue.id}",
            focus_label: issue_focus_label(risk_issue),
            focus_detail:
              "#{risk_issue.project_name || "No project"} · #{risk_issue.assignee_name || "Unassigned"}"
          }

        blocked_goal ->
          {goal, health} = blocked_goal

          %{
            tone: :danger,
            badge: "Goal blocked",
            heading: "Unblock strategic work",
            detail:
              "#{goal.title} has #{health.blocked} blocked linked issue#{plural_suffix(health.blocked)} stopping progress.",
            action_label: "Open blocked goal",
            action_path: "/goals/#{goal.id}",
            focus_label: goal.title,
            focus_detail: "#{health.open} open · #{health.progress_percent}% complete"
          }

        review_goal ->
          {goal, health} = review_goal

          %{
            tone: :review,
            badge: "Evidence ready",
            heading: "Review goal evidence",
            detail:
              "#{goal.title} has #{health.in_review} issue#{plural_suffix(health.in_review)} waiting for review before progress can count.",
            action_label: "Open review goal",
            action_path: "/goals/#{goal.id}",
            focus_label: goal.title,
            focus_detail: "#{health.in_review} in review · #{health.done}/#{health.total} done"
          }

        idle_goal ->
          {goal, health} = idle_goal

          %{
            tone: :idle,
            badge: "Idle goal",
            heading: "Start the idle goal",
            detail:
              "#{goal.title} is active, but no open issue is moving it forward. Create or link execution work.",
            action_label: "Open idle goal",
            action_path: "/goals/#{goal.id}",
            focus_label: goal.title,
            focus_detail: "#{health.done}/#{health.total} linked issues done"
          }

        summary.total_open == 0 ->
          %{
            tone: :empty,
            badge: "No open work",
            heading: "Create the next mission-backed issue",
            detail:
              "Goals are ready, but there is no active work for agents to execute right now.",
            action_label: "Create issue",
            action_path: "/issues/new",
            focus_label: "No active work",
            focus_detail:
              "#{summary.active_goals} active goal#{plural_suffix(summary.active_goals)}"
          }

        true ->
          %{
            tone: :ok,
            badge: "Strategy covered",
            heading: "Keep execution tied to mission",
            detail:
              "#{summary.aligned_percent}% of open work is goal-linked. Review the active goals below before launching more work.",
            action_label: "Create issue",
            action_path: "/issues/new",
            focus_label: "#{summary.mission_aligned}/#{summary.total_open} goal-linked",
            focus_detail:
              "#{summary.goals_with_work} active goal#{plural_suffix(summary.goals_with_work)} with work"
          }
      end

    command
    |> Map.put(:aligned_percent, summary.aligned_percent)
    |> Map.put(:floating_count, summary.floating + summary.project_only)
    |> Map.put(:idle_count, summary.goals_without_work)
    |> Map.put(
      :blocked_goal_count,
      count_goals_with(active_goals, goal_work_health, &(&1.blocked > 0))
    )
    |> Map.put(
      :review_goal_count,
      count_goals_with(active_goals, goal_work_health, &(&1.in_review > 0))
    )
  end

  defp first_goal_with(goals, goal_work_health, predicate) do
    goals
    |> Enum.map(&{&1, goal_health(goal_work_health, &1.id)})
    |> Enum.find(fn {_goal, health} -> predicate.(health) end)
  end

  defp count_goals_with(goals, goal_work_health, predicate) do
    goals
    |> Enum.map(&goal_health(goal_work_health, &1.id))
    |> Enum.count(predicate)
  end

  defp issue_focus_label(%{priority: priority, title: title}) do
    "#{String.capitalize(to_string(priority))} · #{title}"
  end

  def goal_health(goal_work_health, goal_id) do
    Map.get(goal_work_health, goal_id, Goals.empty_goal_work_health())
  end

  defp goal_link_targets(goals) do
    goals
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.sort_by(&{goal_type_rank(&1.goal_type), String.downcase(&1.title || "")})
    |> Enum.map(fn goal ->
      %{
        id: goal.id,
        title: goal.title,
        goal_type: goal.goal_type,
        project_id: goal.project_id,
        label: "#{goal_type_label(goal.goal_type)} · #{goal.title}"
      }
    end)
  end

  defp active_goal?(%{status: "active"}), do: :ok
  defp active_goal?(_goal), do: {:error, :inactive_goal}

  defp issue_goal_attrs(issue, goal) do
    %{goal_id: goal.id}
    |> maybe_inherit_project(issue, goal)
  end

  defp maybe_inherit_project(attrs, %{project_id: nil}, %{project_id: project_id})
       when is_binary(project_id) do
    Map.put(attrs, :project_id, project_id)
  end

  defp maybe_inherit_project(attrs, _issue, _goal), do: attrs

  defp goal_type_rank(:mission), do: 0
  defp goal_type_rank(:initiative), do: 1
  defp goal_type_rank(:milestone), do: 2
  defp goal_type_rank(_), do: 3

  def alignment_status_label(:aligned), do: "Aligned"
  def alignment_status_label(:floating_work), do: "Floating work"
  def alignment_status_label(:missing_goal_links), do: "Missing goal links"
  def alignment_status_label(:no_mission), do: "No active mission"
  def alignment_status_label(:empty), do: "Ready for goals"
  def alignment_status_label(_status), do: "Needs review"

  def alignment_status_detail(:aligned),
    do: "Open work is connected to mission or project context."

  def alignment_status_detail(:floating_work),
    do: "Some open work has no project or goal link, so agents may optimize the wrong outcome."

  def alignment_status_detail(:missing_goal_links),
    do: "Open work exists, but none of it is tied to an active goal yet."

  def alignment_status_detail(:no_mission),
    do: "Create an active mission so new work has a strategic anchor."

  def alignment_status_detail(:empty),
    do: "Create a mission and link issues as work starts."

  def alignment_status_detail(_status), do: "Review goal links before launching more work."

  def alignment_status_class(:aligned),
    do: "border-emerald-400/20 bg-emerald-400/10 text-emerald-300"

  def alignment_status_class(status)
      when status in [:floating_work, :missing_goal_links, :no_mission],
      do: "border-amber-400/20 bg-amber-400/10 text-amber-300"

  def alignment_status_class(_status), do: "border-border bg-surface-1 text-text-tertiary"

  def goal_type_label(:mission), do: "Mission"
  def goal_type_label(:initiative), do: "Initiative"
  def goal_type_label(:milestone), do: "Milestone"
  def goal_type_label(_type), do: "Goal"

  def progress_width(percent) when is_integer(percent), do: "width: #{max(min(percent, 100), 0)}%"
  def progress_width(_percent), do: "width: 0%"

  defp plural_suffix(1), do: ""
  defp plural_suffix(_), do: "s"

  defp goal_command_badge_class(:attention),
    do: "border-amber-400/25 bg-amber-400/10 text-amber-300"

  defp goal_command_badge_class(:danger),
    do: "border-red-400/25 bg-red-400/10 text-red-300"

  defp goal_command_badge_class(:review),
    do: "border-cyan-400/25 bg-cyan-400/10 text-cyan-300"

  defp goal_command_badge_class(:idle),
    do: "border-blue-400/25 bg-blue-400/10 text-blue-300"

  defp goal_command_badge_class(:ok),
    do: "border-emerald-400/25 bg-emerald-400/10 text-emerald-300"

  defp goal_command_badge_class(_),
    do: "border-border bg-surface-1 text-text-tertiary"

  defp goal_command_action_class(:danger),
    do: "border-red-400/25 bg-red-400/10 text-red-300 hover:bg-red-400/15"

  defp goal_command_action_class(:review),
    do: "border-cyan-400/25 bg-cyan-400/10 text-cyan-300 hover:bg-cyan-400/15"

  defp goal_command_action_class(:idle),
    do: "border-blue-400/25 bg-blue-400/10 text-blue-300 hover:bg-blue-400/15"

  defp goal_command_action_class(:ok),
    do: "border-emerald-400/25 bg-emerald-400/10 text-emerald-300 hover:bg-emerald-400/15"

  defp goal_command_action_class(_),
    do: "border-amber-400/25 bg-amber-400/10 text-amber-300 hover:bg-amber-400/15"
end
