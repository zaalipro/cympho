defmodule CymphoWeb.GoalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Goals

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :goals, list_goals(socket))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Goals")
    |> assign(:goal, nil)
  end

  defp apply_action(socket, nil, params) do
    apply_action(socket, :index, params)
  end

  @impl true
  def handle_event("delete_goal", %{"id" => id}, socket) do
    goal = Goals.get_goal!(id)
    {:ok, _} = Goals.delete_goal(goal)
    {:noreply, assign(socket, :goals, list_goals(socket))}
  end

  defp list_goals(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Goals.list_goals_by_company(company_id)
      _ -> Goals.list_goals()
    end
  end
end
