defmodule CymphoWeb.ExecutionPolicyLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        {:ok, assign(socket, execution_policy: policy)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/execution-policies")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        {:noreply,
         socket
         |> assign(:page_title, policy.name)
         |> assign(:execution_policy, policy)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Execution policy not found")
         |> push_navigate(to: ~p"/execution-policies")}
    end
  end
end
