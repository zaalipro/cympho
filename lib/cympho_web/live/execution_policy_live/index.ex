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

    {:noreply,
     socket
     |> assign_policy_command()
     |> reset_stream(:execution_policies, &fetch_execution_policies/1)}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :execution_policies, &fetch_execution_policies/1)}
  end

  defp fetch_execution_policies(cursor) do
    ExecutionPolicies.list_execution_policies_page(after: cursor)
  end

  defp assign_policy_command(socket) do
    assign(socket, :policy_command, build_policy_command(ExecutionPolicies.policy_posture()))
  end

  defp build_policy_command(%{total: 0} = posture) do
    %{
      tone: :idle,
      badge: "No policies",
      heading: "Create a default execution policy before scaling autonomy",
      detail:
        "Policies define who executes, reviews, and approves autonomous work. Start with executor, reviewer, and approver stages.",
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

  defp policy_metrics(posture) do
    [
      %{label: "Policies", value: posture.total, tone: :neutral},
      %{label: "Ready", value: posture.ready_count, tone: :ready},
      %{label: "Needs fix", value: posture.total - posture.ready_count, tone: :danger},
      %{label: "Stages", value: posture.stage_count, tone: :neutral},
      %{label: "Review gates", value: posture.review_gate_count, tone: :review},
      %{label: "Human gates", value: posture.human_gate_count, tone: :human},
      %{label: "Auto", value: posture.auto_advance_count, tone: :auto}
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

  defp policy_status_detail(:ready), do: "Ready to assign to issue execution."
  defp policy_status_detail(:empty), do: "Add at least one stage before assignment."

  defp policy_status_detail(:missing_participant),
    do: "Fill every stage participant before assignment."

  defp policy_status_detail(:no_review_gate),
    do: "Add a reviewer or approver stage for governance coverage."

  defp policy_status_detail(_), do: "Review this policy before assigning it to work."

  defp policy_command_badge_class(:danger), do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp policy_command_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp policy_command_badge_class(:review), do: "border-brand/25 bg-brand/10 text-brand"

  defp policy_command_badge_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp policy_command_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  defp policy_command_action_class(:danger),
    do: "border-red-500/30 bg-red-500/10 text-red-200 hover:bg-red-500/15"

  defp policy_command_action_class(:attention),
    do: "border-amber-500/30 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15"

  defp policy_command_action_class(:review),
    do: "border-brand/30 bg-brand/10 text-brand hover:bg-brand/15"

  defp policy_command_action_class(:healthy),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-200 hover:bg-emerald-500/15"

  defp policy_command_action_class(_),
    do: "border-border bg-surface text-text-secondary hover:bg-surface-hover"

  defp policy_metric_value_class(:ready), do: "text-emerald-300"
  defp policy_metric_value_class(:danger), do: "text-red-300"
  defp policy_metric_value_class(:review), do: "text-brand"
  defp policy_metric_value_class(:human), do: "text-cyan-300"
  defp policy_metric_value_class(:auto), do: "text-amber-300"
  defp policy_metric_value_class(_), do: "text-text-primary"

  defp policy_status_badge_class(:ready),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp policy_status_badge_class(:empty), do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp policy_status_badge_class(:missing_participant),
    do: "border-red-500/25 bg-red-500/10 text-red-300"

  defp policy_status_badge_class(:no_review_gate),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp policy_status_badge_class(_), do: "border-border bg-surface text-text-tertiary"
end
