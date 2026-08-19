defmodule CymphoWeb.ApprovalLive.Show do
  use CymphoWeb, :live_view
  alias Cympho.Approvals

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
           page_title: "Approval #{approval.id}",
           can_resolve_approvals: can_resolve_approvals?(socket)
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
    linked_issue_count = length(approval.issues || [])
    payload_keys = approval.payload |> payload_keys()

    %{
      status_label: status_label(approval.status),
      stance: decision_stance(approval.status),
      recommendation: decision_recommendation(approval, linked_issue_count, payload_keys),
      linked_issue_count: linked_issue_count,
      requested_by: requested_by_label(approval),
      resolved_by: resolved_by_label(approval),
      age: approval_age_label(approval.inserted_at),
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

  defp status_label(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp decision_stance(:pending), do: "Awaiting owner decision"
  defp decision_stance(:approved), do: "Approved path"
  defp decision_stance(:denied), do: "Denied path"
  defp decision_stance(:cancelled), do: "Cancelled path"
  defp decision_stance(_), do: "Decision recorded"

  defp decision_recommendation(%{status: :pending}, linked_issue_count, payload_keys) do
    issue_note =
      if linked_issue_count > 0,
        do: "#{linked_issue_count} linked #{pluralize(linked_issue_count, "issue")} need review.",
        else: "No linked issues are attached."

    payload_note =
      if payload_keys == [],
        do: "Payload is empty.",
        else: "Payload includes #{Enum.join(payload_keys, ", ")}."

    "#{issue_note} Approve only when the evidence is sufficient for the requested action; deny to return the work with a clear stop signal. #{payload_note}"
  end

  defp decision_recommendation(%{status: :approved}, _linked_issue_count, _payload_keys),
    do: "This approval is resolved. The requesting agent can continue on the approved path."

  defp decision_recommendation(%{status: :denied}, _linked_issue_count, _payload_keys),
    do:
      "This approval is denied. The requesting agent should revise the work or stop the proposed action."

  defp decision_recommendation(%{status: :cancelled}, _linked_issue_count, _payload_keys),
    do: "This approval was cancelled before a decision and should not unblock execution."

  defp decision_recommendation(_approval, _linked_issue_count, _payload_keys),
    do: "Decision state recorded."

  defp payload_keys(nil), do: []
  defp payload_keys(payload) when payload == %{}, do: []

  defp payload_keys(payload) when is_map(payload) do
    payload
    |> Map.keys()
    |> Enum.map(&to_string/1)
    |> Enum.sort()
    |> Enum.take(4)
  end

  defp payload_keys(_payload), do: []

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

  defp humanize_key(key) do
    key
    |> to_string()
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
  end

  defp payload_value(value) when is_binary(value), do: value
  defp payload_value(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp payload_value(nil), do: "—"

  defp payload_value(value) do
    case Jason.encode(value) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end

  @doc "Human words for a gate slug: \"release_gate\" -> \"Release gate\"."
  def humanize_type(nil), do: "Approval"

  def humanize_type(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
  end

  defp requested_by_label(%{requested_by: %{name: name}}) when is_binary(name) and name != "",
    do: name

  defp requested_by_label(_approval), do: "Unknown agent"

  defp resolved_by_label(%{resolved_by: %{email: email}}) when is_binary(email) and email != "",
    do: email

  defp resolved_by_label(_approval), do: "Unresolved"

  defp approval_age_label(%DateTime{} = inserted_at) do
    seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m old"
      seconds < 86_400 -> "#{div(seconds, 3600)}h old"
      true -> "#{div(seconds, 86_400)}d old"
    end
  end

  defp approval_age_label(_), do: "unknown age"

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  # Pending is the only accented state — resolved records read as a calm,
  # settled ledger. Emerald and red are reserved for the Approve/Deny actions.
  def decision_packet_tone(:pending), do: "border-brand/30 bg-brand/[0.06]"
  def decision_packet_tone(_), do: "border-border bg-surface-1"

  def decision_packet_status_class(:pending),
    do: "border-brand/30 bg-brand/10 text-brand"

  def decision_packet_status_class(_),
    do: "border-border bg-surface text-text-tertiary"

  def detail_stat_class do
    "rounded-lg border border-border bg-surface-1 px-4 py-3"
  end
end
