defmodule CymphoWeb.ExecutionPolicyLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :execution_policies, ExecutionPolicies.list_execution_policies())}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

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
    {:noreply, assign(socket, :execution_policies, ExecutionPolicies.list_execution_policies())}
  end
end