defmodule CymphoWeb.BoardApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.{BoardApprovals, GovernanceRisk}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      BoardApprovals.subscribe(socket.assigns.current_company.id)
    end

    case fetch_company_board_approval(socket, id) do
      {:ok, approval} ->
        {:ok, assign_approval(socket, approval)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  defp fetch_company_board_approval(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> BoardApprovals.get_company_board_approval(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_info({:board_approval_resolved, updated_approval}, socket) do
    if socket.assigns.approval.id == updated_approval.id do
      {:noreply, assign_approval(socket, updated_approval)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:board_vote_cast, vote}, socket) do
    if socket.assigns.approval.id == vote.board_approval_id do
      case fetch_company_board_approval(socket, vote.board_approval_id) do
        {:ok, approval} -> {:noreply, assign_approval(socket, approval)}
        {:error, :not_found} -> {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp assign_approval(socket, approval) do
    assign(socket,
      approval: approval,
      governance_risk: GovernanceRisk.approval_brief(approval),
      page_title: approval.title
    )
  end

  def status_badge("pending"), do: "bg-yellow-500/10 text-yellow-500 border-yellow-500/20"
  def status_badge("approved"), do: "bg-green-500/10 text-green-500 border-green-500/20"
  def status_badge("denied"), do: "bg-brand/10 text-brand border-brand/20"
  def status_badge("cancelled"), do: "bg-gray-500/10 text-gray-500 border-gray-500/20"
  def status_badge("expired"), do: "bg-gray-500/10 text-gray-500 border-gray-500/20"

  def risk_badge(:critical), do: "border-red-500/25 bg-red-500/10 text-red-300"
  def risk_badge(:warning), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  def risk_badge(:healthy), do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"
  def risk_badge(:resolved), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  def risk_badge(_), do: "border-border bg-surface text-text-tertiary"

  def signal_class(:danger), do: "border-red-500/20 bg-red-500/10 text-red-100"
  def signal_class(:attention), do: "border-amber-500/20 bg-amber-500/10 text-amber-100"
  def signal_class(:ok), do: "border-emerald-500/20 bg-emerald-500/10 text-emerald-100"
  def signal_class(_), do: "border-border bg-surface text-text-secondary"

  def category_label("agent_hire"), do: "Agent Hire"
  def category_label("agent_termination"), do: "Agent Termination"
  def category_label("agent_promotion"), do: "Agent Promotion"
  def category_label("budget_increase"), do: "Budget Increase"
  def category_label("policy_change"), do: "Policy Change"
  def category_label("security_exception"), do: "Security Exception"
  def category_label("principal_permission"), do: "Principal Permission"
  def category_label("strategic_initiative"), do: "Strategic Initiative"
  def category_label(_), do: "Other"

  def format_datetime(datetime) when not is_nil(datetime) do
    datetime
    |> DateTime.to_string()
    |> String.replace("Z", "")
    |> String.slice(0, 19)
  end

  def format_datetime(_), do: "N/A"
end
