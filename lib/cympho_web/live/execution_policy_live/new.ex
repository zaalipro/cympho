defmodule CymphoWeb.ExecutionPolicyLive.New do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy
  alias CymphoWeb.ExecutionPolicyLive.FormHelpers

  @impl true
  def mount(_params, _session, socket) do
    changeset =
      ExecutionPolicies.change_execution_policy(%ExecutionPolicy{
        stage_configs: FormHelpers.default_stage_configs()
      })

    socket =
      assign(socket,
        changeset: changeset,
        form: to_form(changeset),
        page_title: "New Execution Policy",
        stage_configs_text: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("save", %{"execution_policy" => policy_params}, socket) do
    case FormHelpers.normalize_policy_params(policy_params) do
      {:ok, normalized_params} ->
        case ExecutionPolicies.create_execution_policy(normalized_params) do
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
            %ExecutionPolicy{},
            policy_params,
            message,
            :insert
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
          %ExecutionPolicy{}
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
            %ExecutionPolicy{},
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
