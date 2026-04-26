defmodule CymphoWeb.ActivityLive.DashboardComponent do
  use CymphoWeb, :live_component
  import Ecto.Query
  alias Cympho.Activities

  @impl true
  def update(%{issue_id: issue_id} = assigns, socket) do
    if connected?(socket) do
      company_id =
        Cympho.Repo.one(
          from i in Cympho.Issues.Issue, where: i.id == ^issue_id, select: i.company_id
        )

      if company_id, do: Activities.subscribe(company_id)
    end

    statistics = Activities.get_activity_statistics(issue_id)
    activities = Activities.list_activities(issue_id)

    socket =
      socket
      |> assign(assigns)
      |> assign(:statistics, statistics)
      |> assign(:activities, activities)
      |> assign(:chart_data, prepare_chart_data(activities))

    {:ok, socket}
  end

  def handle_info({:activity_created, _activity}, socket) do
    activities = Activities.list_activities(socket.assigns.issue_id)
    statistics = Activities.get_activity_statistics(socket.assigns.issue_id)

    {:noreply,
     assign(socket,
       activities: activities,
       statistics: statistics,
       chart_data: prepare_chart_data(activities)
     )}
  end

  def handle_info(_, socket) do
    {:noreply, socket}
  end

  defp prepare_chart_data(activities) do
    by_action =
      activities
      |> Enum.group_by(& &1.action)
      |> Enum.map(fn {action, items} -> {action, length(items)} end)
      |> Enum.sort_by(fn {_action, count} -> count end, :desc)

    by_actor =
      activities
      |> Enum.group_by(& &1.actor_type)
      |> Enum.map(fn {actor, items} -> {actor, length(items)} end)

    timeline =
      activities
      |> Enum.group_by(fn activity ->
        DateTime.to_date(activity.inserted_at)
      end)
      |> Enum.map(fn {date, items} -> {date, length(items)} end)
      |> Enum.sort_by(fn {date, _count} -> date end)

    %{
      by_action: by_action,
      by_actor: by_actor,
      timeline: timeline
    }
  end

  defp max_count(%{by_action: by_action}) do
    if Enum.empty?(by_action),
      do: 0,
      else: Enum.max_by(by_action, fn {_action, count} -> count end) |> elem(1)
  end

  defp action_color("created"), do: "#4ade80"
  defp action_color("updated"), do: "#60a5fa"
  defp action_color("deleted"), do: "#f87171"
  defp action_color("commented"), do: "#fbbf24"
  defp action_color("assigned"), do: "#c084fc"
  defp action_color("unassigned"), do: "#a78bfa"
  defp action_color(_), do: "#7170ff"

  defp actor_color("user"), do: "#60a5fa"
  defp actor_color("system"), do: "#fbbf24"
  defp actor_color("agent"), do: "#4ade80"
  defp actor_color(_), do: "#7170ff"
end
