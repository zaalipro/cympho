defmodule CymphoWeb.GoalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Goals

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case get_scoped_goal(socket, id) do
      {:ok, goal} ->
        {:ok, assign(socket, goal: goal)}

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

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Goal not found")
        |> push_navigate(to: ~p"/goals")
    end
  end

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
