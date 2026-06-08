defmodule CymphoWeb.ExecutionPolicyLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:infinite_scroll, %{})
     |> init_stream(:execution_policies, &fetch_execution_policies/1)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, _params), do: apply_action(socket, :index, %{})

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Execution Policies")
    |> assign(:execution_policy, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Execution Policy")
    |> assign(:execution_policy, %ExecutionPolicy{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    socket
    |> assign(:page_title, "Edit Execution Policy")
    |> assign(:execution_policy, ExecutionPolicies.get_execution_policy!(id))
  end

  @impl true
  def handle_event("delete_execution_policy", %{"id" => id}, socket) do
    policy = ExecutionPolicies.get_execution_policy!(id)
    {:ok, _} = ExecutionPolicies.delete_execution_policy(policy)
    {:noreply, reset_stream(socket, :execution_policies, &fetch_execution_policies/1)}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :execution_policies, &fetch_execution_policies/1)}
  end

  defp fetch_execution_policies(cursor) do
    ExecutionPolicies.list_execution_policies_page(after: cursor)
  end
end
