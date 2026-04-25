defmodule CymphoWeb.ExecutionPolicyLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        changeset = ExecutionPolicies.change_execution_policy(policy)

        {:ok,
         assign(socket, execution_policy: policy, changeset: changeset, form: to_form(changeset))}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/execution-policies")}
    end
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        changeset = ExecutionPolicies.change_execution_policy(policy)

        {:noreply,
         socket
         |> assign(:page_title, "Edit #{policy.name}")
         |> assign(:execution_policy, policy)
         |> assign(:changeset, changeset)
         |> assign(:form, to_form(changeset))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Execution policy not found")
         |> push_navigate(to: ~p"/execution-policies")}
    end
  end

  @impl true
  def handle_event("save", %{"execution_policy" => policy_params}, socket) do
    case ExecutionPolicies.update_execution_policy(socket.assigns.execution_policy, policy_params) do
      {:ok, policy} ->
        {:noreply, push_navigate(socket, to: ~p"/execution-policies/#{policy.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, changeset: changeset, form: to_form(changeset))}
    end
  end
end
