defmodule CymphoWeb.ExecutionPolicyLive.New do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @impl true
  def mount(_params, _session, socket) do
    changeset = ExecutionPolicies.change_execution_policy(%ExecutionPolicy{})
    socket = assign(socket, changeset: changeset, page_title: "New Execution Policy")
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"execution_policy" => policy_params}, socket) do
    case ExecutionPolicies.create_execution_policy(policy_params) do
      {:ok, policy} ->
        {:noreply, push_navigate(socket, to: ~p"/execution-policies/#{policy.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset)}
    end
  end
end