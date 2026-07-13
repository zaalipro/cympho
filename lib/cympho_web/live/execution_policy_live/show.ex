defmodule CymphoWeb.ExecutionPolicyLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        {:ok, assign(socket, execution_policy: policy)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/settings/policies")}
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
         |> push_navigate(to: ~p"/settings/policies")}
    end
  end

  def stage_count_label(stage_configs) do
    case length(stage_configs) do
      1 -> "1 stage"
      count -> "#{count} stages"
    end
  end

  def truthy_flag(stage, key) do
    (Map.get(stage, key) || Map.get(stage, String.to_atom(key))) in [true, "true", 1, "1", "on"]
  end
end
