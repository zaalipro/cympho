defmodule CymphoWeb.BoardApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.{BoardApprovals, Companies, GovernanceRisk}
  alias CymphoWeb.UserAuth

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

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :from, UserAuth.safe_from(params["from"]))}
  end

  defp fetch_company_board_approval(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> BoardApprovals.get_company_board_approval(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  @impl true
  def handle_event("cast_vote", %{"vote" => vote} = params, socket)
      when vote in ["approve", "deny", "abstain"] do
    user = socket.assigns.current_user
    company = socket.assigns.current_company
    approval = socket.assigns.approval

    if user && company && Companies.is_board_member?(user.id, company.id) do
      case BoardApprovals.cast_vote(approval.id, user.id, vote, vote_reason(params["reason"])) do
        {:ok, _vote} ->
          {:noreply, push_event(socket, "toast", %{message: "Vote recorded.", type: "success"})}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not cast vote")}
      end
    else
      {:noreply, socket}
    end
  end

  defp vote_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> nil
      reason -> reason
    end
  end

  defp vote_reason(_reason), do: nil

  # The broadcast approval does not preload :votes, which the page renders, so
  # reload it through the company-scoped query instead of assigning it.
  @impl true
  def handle_info({:board_approval_resolved, updated_approval}, socket) do
    if socket.assigns.approval.id == updated_approval.id do
      case fetch_company_board_approval(socket, updated_approval.id) do
        {:ok, approval} -> {:noreply, assign_approval(socket, approval)}
        {:error, :not_found} -> {:noreply, socket}
      end
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
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    board_member? =
      is_binary(user_id) and is_binary(company_id) and
        Companies.is_board_member?(user_id, company_id)

    assign(socket,
      approval: approval,
      governance_risk: GovernanceRisk.approval_brief(approval),
      page_title: approval.title,
      board_member?: board_member?,
      voted?: is_binary(user_id) and Enum.any?(approval.votes, &(&1.user_id == user_id))
    )
  end

  # A word plus a shape (v7 §1.5) for the approval, the risk level, a signal and a vote.
  def status("pending"), do: {:waiting, "Waiting for votes"}
  def status("approved"), do: {:done, "Approved"}
  def status("denied"), do: {:stopped, "Denied"}
  def status("cancelled"), do: {:idle, "Cancelled"}
  def status("expired"), do: {:idle, "Expired"}
  def status(other), do: {:idle, other |> to_string() |> String.capitalize()}

  def risk_kind(:critical), do: :stopped
  def risk_kind(:warning), do: :waiting
  def risk_kind(level) when level in [:healthy, :resolved], do: :done
  def risk_kind(_level), do: :idle

  def signal_status(:danger), do: {:stopped, "Problem"}
  def signal_status(:attention), do: {:waiting, "Watch"}
  def signal_status(:ok), do: {:done, "OK"}
  def signal_status(_tone), do: {:idle, "Not checked"}

  def vote_status("approve"), do: {:done, "Approved"}
  def vote_status("deny"), do: {:stopped, "Denied"}
  def vote_status("abstain"), do: {:idle, "Abstained"}
  def vote_status(other), do: {:idle, other |> to_string() |> String.capitalize()}

  def category_label("agent_hire"), do: "Agent hire"
  def category_label("agent_termination"), do: "Agent termination"
  def category_label("agent_promotion"), do: "Agent promotion"
  def category_label("budget_increase"), do: "Budget increase"
  def category_label("policy_change"), do: "Policy change"
  def category_label("security_exception"), do: "Security exception"
  def category_label("principal_permission"), do: "Principal permission"
  def category_label("strategic_initiative"), do: "Strategic initiative"
  def category_label(_), do: "Other"

  defp day(at), do: Calendar.strftime(at, "%a %-d %b")
  defp clock(at), do: Calendar.strftime(at, "%H:%M")
end
