defmodule CymphoWeb.ApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Approvals
  alias CymphoWeb.AgentLive.Parts
  alias CymphoWeb.ApprovalLive.Index
  alias CymphoWeb.UserAuth

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case fetch_company_approval(socket, id) do
      {:ok, approval} ->
        if connected?(socket) && socket.assigns[:current_company] do
          Approvals.subscribe(socket.assigns.current_company.id)
        end

        {:ok,
         socket
         |> assign(
           approval: approval,
           page_title: humanize_type(approval.type),
           can_resolve_approvals: can_resolve_approvals?(socket),
           from: nil
         )
         |> assign_decision_packet()}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/approvals")}
    end
  end

  defp fetch_company_approval(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Approvals.get_company_approval(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  # Links from Home and Inbox carry ?from= (NextStep), so the page offers "Back to …" (v7 G2).
  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, assign(socket, :from, UserAuth.safe_from(params["from"]))}
  end

  @impl true
  def handle_event("approve", _params, socket) do
    case resolve_approval(socket, :approved, "Approved via UI") do
      {:ok, approval} ->
        {:noreply,
         socket
         |> assign(:approval, approval)
         |> assign_decision_packet()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, resolver_forbidden_message())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approve")}
    end
  end

  def handle_event("deny", _params, socket) do
    case resolve_approval(socket, :denied, "Denied via UI") do
      {:ok, approval} ->
        {:noreply,
         socket
         |> assign(:approval, approval)
         |> assign_decision_packet()}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, resolver_forbidden_message())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to deny")}
    end
  end

  @impl true
  def handle_info({:approval_resolved, updated}, socket) do
    if socket.assigns.approval.id == updated.id do
      {:noreply,
       socket
       |> assign(:approval, updated)
       |> assign_decision_packet()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp assign_decision_packet(socket) do
    assign(socket, :decision_packet, build_decision_packet(socket.assigns.approval))
  end

  defp build_decision_packet(approval) do
    %{
      requested_by: requested_by_label(approval),
      resolved_by: resolved_by_label(approval),
      resolution: approval.resolution_reason || "No resolution recorded yet."
    }
  end

  defp resolve_approval(socket, decision, reason) do
    with %{id: company_id} <- socket.assigns[:current_company],
         %{id: user_id} <- socket.assigns[:current_user] do
      Approvals.resolve_company_approval(
        company_id,
        socket.assigns.approval.id,
        decision,
        %{resolved_by_user_id: user_id, resolution_reason: reason}
      )
    else
      _ -> {:error, :forbidden}
    end
  end

  defp can_resolve_approvals?(socket) do
    with %{id: company_id} <- socket.assigns[:current_company],
         %{id: user_id} <- socket.assigns[:current_user] do
      Approvals.resolver_authorized?(user_id, company_id)
    else
      _ -> false
    end
  end

  defp resolver_forbidden_message,
    do: "Only company owners, admins, and board members can resolve approvals."

  @doc """
  The approval's state as a word and its shape (v7 §1.5): pending reads
  "Waiting for you" only for someone who can resolve it.
  """
  def status(:pending, true), do: {:waiting, "Waiting for you"}
  def status(:pending, _can_resolve), do: {:waiting, "Waiting for a decision"}
  def status(:approved, _can_resolve), do: {:done, "Approved"}
  def status(:denied, _can_resolve), do: {:stopped, "Denied"}
  def status(:cancelled, _can_resolve), do: {:idle, "Cancelled"}

  def status(other, _can_resolve),
    do: {:idle, other |> to_string() |> String.replace("_", " ") |> String.capitalize()}

  # A linked task's state in the owner's words (the Task page's).
  @task_states %{
    backlog: "Later",
    todo: "To do",
    in_progress: "Working",
    in_review: "In review",
    blocked: "Blocked",
    done: "Done",
    cancelled: "Cancelled"
  }
  def task_state(status), do: Map.get(@task_states, status, to_string(status))

  defp day(at), do: Calendar.strftime(at, "%a %-d %b")
  defp clock(at), do: Calendar.strftime(at, "%H:%M")
  defp initials(name), do: Parts.initials(name)

  @doc """
  Payload rendered as readable `{label, value}` pairs for a definition
  list — the human-first view of the decision evidence. Nested values are
  compacted to JSON; the raw dump stays behind advanced disclosure.
  """
  def payload_entries(payload) when is_map(payload) do
    payload
    |> Enum.map(fn {key, value} -> {humanize_key(key), payload_value(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  def payload_entries(_payload), do: []

  defp humanize_key(key), do: key |> to_string() |> humanize_type()

  defp payload_value(value) when is_binary(value), do: value
  defp payload_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp payload_value(nil), do: "—"

  defp payload_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end

  defdelegate humanize_type(type), to: Index

  defp requested_by_label(%{requested_by: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp requested_by_label(_approval), do: "Unknown agent"

  defp resolved_by_label(%{resolved_by: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp resolved_by_label(%{resolved_by: %{email: email}}) when is_binary(email) and email != "",
    do: email

  defp resolved_by_label(_approval), do: "Unresolved"
end
