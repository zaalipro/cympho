defmodule CymphoWeb.ExecutionPolicyLive.Edit do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias CymphoWeb.ExecutionPolicyLive.FormHelpers

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case ExecutionPolicies.get_execution_policy(id) do
      {:ok, policy} ->
        changeset = ExecutionPolicies.change_execution_policy(policy)

        {:ok,
         assign(socket,
           execution_policy: policy,
           changeset: changeset,
           form: to_form(changeset),
           stage_configs_text: nil
         )}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/settings/policies")}
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
         |> assign(:form, to_form(changeset))
         |> assign(:stage_configs_text, nil)}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Execution policy not found")
         |> push_navigate(to: ~p"/settings/policies")}
    end
  end

  @impl true
  def handle_event("save", %{"execution_policy" => policy_params}, socket) do
    case FormHelpers.normalize_policy_params(policy_params) do
      {:ok, normalized_params} ->
        case ExecutionPolicies.update_execution_policy(
               socket.assigns.execution_policy,
               normalized_params
             ) do
          {:ok, policy} ->
            {:noreply, push_navigate(socket, to: ~p"/settings/policies/#{policy.id}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket,
               changeset: changeset,
               form: to_form(changeset),
               stage_configs_text: nil
             )}
        end

      {:error, message} ->
        changeset =
          FormHelpers.form_error_changeset(
            socket.assigns.execution_policy,
            policy_params,
            message,
            :update
          )

        {:noreply,
         assign(socket,
           changeset: changeset,
           form: to_form(changeset),
           stage_configs_text: policy_params["stage_configs"]
         )}
    end
  end

  def handle_event("validate", %{"execution_policy" => policy_params}, socket) do
    case FormHelpers.normalize_policy_params(policy_params) do
      {:ok, normalized_params} ->
        changeset =
          socket.assigns.execution_policy
          |> ExecutionPolicies.change_execution_policy(normalized_params)
          |> Map.put(:action, :validate)

        {:noreply,
         assign(socket,
           changeset: changeset,
           form: to_form(changeset),
           stage_configs_text: FormHelpers.stage_configs_text_from_params(normalized_params)
         )}

      {:error, message} ->
        changeset =
          FormHelpers.form_error_changeset(
            socket.assigns.execution_policy,
            policy_params,
            message,
            :validate
          )

        {:noreply,
         assign(socket,
           changeset: changeset,
           form: to_form(changeset),
           stage_configs_text: policy_params["stage_configs"]
         )}
    end
  end
end
