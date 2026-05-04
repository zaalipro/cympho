defmodule CymphoWeb.GoalLive.Show do
  use CymphoWeb, :live_view
  import Ecto.Query
  alias Cympho.{Goals, Repo}
  alias Cympho.Issues.Issue

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        {:ok,
         socket
         |> assign(:goal, goal)
         |> assign(:issues, list_goal_issues(goal))
         |> assign(:status_counts, status_counts(goal))}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/goals")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, id)}
  end

  defp apply_action(socket, nil, id), do: apply_action(socket, :show, id)

  defp apply_action(socket, :show, id) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        socket
        |> assign(:page_title, goal.title)
        |> assign(:goal, goal)
        |> assign(:issues, list_goal_issues(goal))
        |> assign(:status_counts, status_counts(goal))

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Goal not found")
        |> push_navigate(to: ~p"/goals")
    end
  end

  defp list_goal_issues(%{id: goal_id}) do
    Issue
    |> where(goal_id: ^goal_id)
    |> order_by(desc: :inserted_at)
    |> limit(10)
    |> Repo.all()
  end

  defp status_counts(%{id: goal_id}) do
    Issue
    |> where(goal_id: ^goal_id)
    |> group_by(:status)
    |> select([i], {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  def status_label(:in_progress), do: "In progress"
  def status_label(:in_review), do: "In review"
  def status_label(s), do: s |> to_string() |> String.capitalize()

  defp get_scoped_goal(socket, id) do
    with {:ok, goal} <- Goals.get_goal(id),
         :ok <- authorize_goal(socket, goal) do
      {:ok, goal}
    end
  end

  defp authorize_goal(socket, goal) do
    case socket.assigns[:current_company] do
      %{id: company_id} when goal.company_id == company_id -> :ok
      nil -> :ok
      _ -> {:error, :not_found}
    end
  end
end
