defmodule CymphoWeb.BoardApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.BoardApprovals

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    BoardApprovals.subscribe(socket.assigns.current_company.id)

    case BoardApprovals.get_board_approval(id) do
      {:ok, approval} ->
        {:ok, assign(socket, approval: approval, page_title: approval.title)}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_info({:board_approval_resolved, updated_approval}, socket) do
    if socket.assigns.approval.id == updated_approval.id do
      {:noreply, assign(socket, :approval, updated_approval)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  def status_badge("pending"), do: "bg-yellow-500/10 text-yellow-500 border-yellow-500/20"
  def status_badge("approved"), do: "bg-green-500/10 text-green-500 border-green-500/20"
  def status_badge("denied"), do: "bg-red-500/10 text-red-500 border-red-500/20"
  def status_badge("cancelled"), do: "bg-gray-500/10 text-gray-500 border-gray-500/20"
  def status_badge("expired"), do: "bg-gray-500/10 text-gray-500 border-gray-500/20"

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
