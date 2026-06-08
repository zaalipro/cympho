defmodule CymphoWeb.GoalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Goals

  @impl true
  def mount(_params, _session, socket) do
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
end
