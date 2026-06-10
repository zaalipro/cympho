defmodule CymphoWeb.GoalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Goals

  @impl true
  def mount(_params, _session, socket) do
    socket = assign_goal_overview(socket)

    {:ok,
     socket
     |> assign(:infinite_scroll, %{})
     |> init_stream(:goals, &fetch_goals(socket, &1))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Goals")
    |> assign(:goal, nil)
    |> assign_goal_overview()
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

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
        socket
        |> assign(:alignment_summary, Goals.alignment_summary(company_id))
        |> assign(:goal_work_health, Goals.goal_work_health(company_id))

      _ ->
        socket
        |> assign(:alignment_summary, Goals.empty_alignment_summary())
        |> assign(:goal_work_health, %{})
    end
  end

  def goal_health(goal_work_health, goal_id) do
    Map.get(goal_work_health, goal_id, Goals.empty_goal_work_health())
  end

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
end
