defmodule CymphoWeb.ExecutionPolicyLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.ExecutionPolicies
  alias Cympho.ExecutionPolicies.ExecutionPolicy

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:infinite_scroll, %{})
     |> assign_policy_command()
     |> init_stream(:execution_policies, &fetch_execution_policies(socket, &1))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, nil, _params), do: apply_action(socket, :index, %{})

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Review steps")
    |> assign(:execution_policy, nil)
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Execution Policy")
    |> assign(:execution_policy, %ExecutionPolicy{})
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    case ExecutionPolicies.get_company_execution_policy(socket.assigns.current_company.id, id) do
      {:ok, policy} ->
        socket
        |> assign(:page_title, "Edit Execution Policy")
        |> assign(:execution_policy, policy)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Policy not found")
        |> push_navigate(to: ~p"/settings/policies")
    end
  end

  @impl true
  def handle_event("delete_execution_policy", %{"id" => id}, socket) do
    case ExecutionPolicies.get_company_execution_policy(socket.assigns.current_company.id, id) do
      {:ok, policy} ->
        {:ok, _} = ExecutionPolicies.delete_execution_policy(policy)

        {:noreply,
         socket
         |> assign_policy_command()
         |> reset_stream(:execution_policies, &fetch_execution_policies(socket, &1))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Policy not found")
         |> push_navigate(to: ~p"/settings/policies")}
    end
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :execution_policies, &fetch_execution_policies(socket, &1))}
  end

  defp fetch_execution_policies(socket, cursor) do
    ExecutionPolicies.list_execution_policies_page(socket.assigns.current_company.id,
      after: cursor
    )
  end

  defp assign_policy_command(socket) do
    policies = ExecutionPolicies.list_execution_policies(socket.assigns.current_company.id)

    assign(
      socket,
      :policy_command,
      build_policy_command(ExecutionPolicies.policy_posture(policies))
    )
  end

  defp build_policy_command(%{total: 0} = posture) do
    %{
      tone: :idle,
      badge: "No policies",
      heading: "Create a default execution policy before scaling autonomy",
      detail: "A policy says who does the work, who reviews it, and who approves it.",
      focus_label: nil,
      focus_detail: nil,
      action_path: ~p"/settings/policies/new",
      action_label: "New policy",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(%{empty_count: count, attention_policy: policy} = posture)
       when count > 0 do
    %{
      tone: :danger,
      badge: "Incomplete",
      heading: "Add stages to policies before assigning them to work",
      detail:
        "A policy with no stages cannot initialize execution state. Add executor, reviewer, and approver stages before using it.",
      focus_label: policy && policy.name,
      focus_detail: policy && "0 configured stages",
      action_path: policy_path(policy, :edit),
      action_label: "Fix policy",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(
         %{missing_participant_count: count, attention_policy: policy} = posture
       )
       when count > 0 do
    %{
      tone: :danger,
      badge: "Missing people",
      heading: "Assign missing participants in policy stages",
      detail:
        "Stages without participants create handoff ambiguity. Fill every executor, reviewer, and approver before assigning the policy.",
      focus_label: policy && policy.name,
      focus_detail: policy && "#{policy.missing_participant_count} missing participants",
      action_path: policy_path(policy, :edit),
      action_label: "Assign participants",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(%{review_gate_count: review_count, total: total} = posture)
       when review_count < total do
    policy = posture.attention_policy

    %{
      tone: :attention,
      badge: "Review gap",
      heading: "Add reviewer or approver gates to every policy",
      detail:
        "Executor-only flows are fast, but they do not create a governance checkpoint before work moves forward.",
      focus_label: policy && policy.name,
      focus_detail: policy && stage_mix_label(policy),
      action_path: policy_path(policy, :edit),
      action_label: "Add gate",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(%{different_actor_count: 0} = posture) do
    %{
      tone: :review,
      badge: "Independence",
      heading: "Require an independent reviewer where risk matters",
      detail:
        "At least one policy should require a different actor for review or approval so agents cannot approve their own work.",
      focus_label: "No policy enforces different-actor review",
      focus_detail: nil,
      action_path: ~p"/settings/policies/new",
      action_label: "Add policy",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(%{human_gate_count: 0} = posture) do
    %{
      tone: :review,
      badge: "Human gate",
      heading: "Add a human approval gate for high-risk work",
      detail:
        "Human-required stages let owners reserve final authority for spend, production, and governance-sensitive changes.",
      focus_label: "No policy requires human approval",
      focus_detail: nil,
      action_path: ~p"/settings/policies/new",
      action_label: "Add policy",
      metrics: policy_metrics(posture)
    }
  end

  defp build_policy_command(posture) do
    %{
      tone: :healthy,
      badge: "Governed",
      heading: "Execution policies are ready for autonomous work",
      detail:
        "Configured policies include review coverage, participants, and independence controls for safer agent execution.",
      focus_label: "#{posture.ready_count} ready policies",
      focus_detail: "#{posture.stage_count} total stages",
      action_path: ~p"/settings/policies/new",
      action_label: "New policy",
      metrics: policy_metrics(posture)
    }
  end

  defp policy_metric_total(%{metrics: [%{value: total} | _]}), do: total
  defp policy_metric_total(_command), do: 0

  # One strip of at most four cells (v7 P7); the total stays first (policy_metric_total/1).
  defp policy_metrics(posture) do
    [
      %{label: "Review steps", value: posture.total},
      %{label: "Ready", value: posture.ready_count},
      %{label: "Need a fix", value: posture.total - posture.ready_count},
      %{label: "Human gates", value: posture.human_gate_count}
    ]
  end

  defp policy_path(nil, _action), do: ~p"/settings/policies"
  defp policy_path(%{id: id}, :edit), do: ~p"/settings/policies/#{id}/edit"
  defp policy_path(%{id: id}, _action), do: ~p"/settings/policies/#{id}"

  defp policy_summary(policy), do: ExecutionPolicies.policy_summary(policy)

  defp stage_mix_label(%{stage_types: []}), do: "No stages"

  defp stage_mix_label(%{stage_types: types}) do
    types
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" -> ")
  end

  defp policy_status_label(:ready), do: "Ready"
  defp policy_status_label(:empty), do: "No stages"
  defp policy_status_label(:missing_participant), do: "Missing people"
  defp policy_status_label(:no_review_gate), do: "Review gap"
  defp policy_status_label(_), do: "Needs review"

  # Status as a word plus a shape (v7 §1.5): ready is done, anything else waits on a fix.
  defp policy_status(:ready), do: {:done, policy_status_label(:ready)}
  defp policy_status(status), do: {:waiting, policy_status_label(status)}

  # ["3 stages", "Executor, reviewer, approver", "Different actor", "Human approval"]
  defp policy_meta(summary) do
    [
      stage_count_label(summary.stage_count),
      stage_types_label(summary.stage_types),
      summary.has_different_actor_gate? && "Different actor",
      summary.has_human_gate? && "Human approval"
    ]
    |> Enum.filter(&is_binary/1)
  end

  defp stage_count_label(1), do: "1 stage"
  defp stage_count_label(count), do: "#{count} stages"

  defp stage_types_label(types) do
    case Enum.reject(types, &(&1 in [nil, ""])) do
      [] -> nil
      types -> types |> Enum.join(", ") |> String.capitalize()
    end
  end
end
