defmodule CymphoWeb.ApprovalLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Approvals
  alias Cympho.Approvals.Approval

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Approvals.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     assign(socket,
       page_title: "Approval history",
       status_filter: nil,
       can_resolve_approvals: can_resolve_approvals?(socket),
       approval_command: empty_approval_command(),
       infinite_scroll: %{}
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = parse_status(Map.get(params, "status"))

    {:noreply,
     socket
     |> assign(:status_filter, status)
     |> assign(:approval_command, build_approval_command(socket, status))
     |> init_stream(:approvals, &fetch_approvals(socket, &1, status))}
  end

  @impl true
  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: approval_filter_path(parse_status(status)))}
  end

  def handle_event("next-page", _params, socket) do
    status = socket.assigns.status_filter
    {:reply, %{}, load_next(socket, :approvals, &fetch_approvals(socket, &1, status))}
  end

  def handle_event("approve", %{"id" => id}, socket) do
    resolve_inline(socket, id, :approved, "Approved via approvals queue")
  end

  def handle_event("deny", %{"id" => id}, socket) do
    resolve_inline(socket, id, :denied, "Denied via approvals queue")
  end

  @impl true
  def handle_info({:approval_created, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info({:approval_resolved, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info({:approval_cancelled, _approval}, socket) do
    {:noreply, reload_approvals(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  defp reload_approvals(socket) do
    status = socket.assigns.status_filter

    socket
    |> assign(:approval_command, build_approval_command(socket, status))
    |> reset_stream(:approvals, &fetch_approvals(socket, &1, status))
  end

  # Inline decision from the queue. Guards the approval to the current
  # company before resolving; the :approval_resolved broadcast then
  # refreshes the stream for every subscribed view.
  defp resolve_inline(socket, id, decision, reason) do
    with %{id: company_id} <- socket.assigns[:current_company],
         %{id: user_id} <- socket.assigns[:current_user],
         {:ok, _resolved} <-
           Approvals.resolve_company_approval(company_id, id, decision, %{
             resolved_by_user_id: user_id,
             resolution_reason: reason
           }) do
      {:noreply,
       socket
       |> put_flash(:info, if(decision == :approved, do: "Approved", else: "Denied"))
       |> reload_approvals()}
    else
      {:error, :forbidden} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Only company owners, admins, and board members can resolve approvals."
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not resolve approval")}
    end
  end

  defp can_resolve_approvals?(socket) do
    with %{id: user_id} <- socket.assigns[:current_user],
         %{id: company_id} <- socket.assigns[:current_company] do
      Approvals.resolver_authorized?(user_id, company_id)
    else
      _ -> false
    end
  end

  defp fetch_approvals(socket, cursor, status) do
    case socket.assigns[:current_company] do
      nil ->
        %Cympho.Pagination.Page{entries: [], next_cursor: nil, has_more?: false}

      company ->
        Approvals.list_approvals_page(%{
          company_id: company.id,
          status: status,
          after: cursor
        })
    end
  end

  defp build_approval_command(socket, active_status) do
    approvals = company_approvals(socket)
    counts = approval_counts(approvals)
    pending = Map.get(counts, :pending, 0)
    resolved = Map.get(counts, :approved, 0) + Map.get(counts, :denied, 0)
    oldest_pending = oldest_pending(approvals)

    %{
      counts: counts,
      pending_count: pending,
      resolved_count: resolved,
      oldest_pending_label: approval_type_label(oldest_pending),
      summary: approval_command_summary(pending, resolved, oldest_pending, active_status),
      lanes: approval_lanes(counts, active_status),
      actions: approval_command_actions(pending, active_status)
    }
  end

  defp empty_approval_command do
    %{
      counts: %{},
      pending_count: 0,
      resolved_count: 0,
      oldest_pending_label: approval_type_label(nil),
      summary: "No approvals queued.",
      lanes: approval_lanes(%{}, nil),
      actions: [
        %{label: "All approvals", url: ~p"/approvals"},
        %{label: "Activity", url: ~p"/activity?filter_action=approval_created"}
      ]
    }
  end

  defp company_approvals(socket) do
    case socket.assigns[:current_company] do
      nil -> []
      company -> Approvals.list_approvals(%{company_id: company.id})
    end
  end

  defp approval_counts(approvals) do
    base = Map.new(Approval.status_values(), &{&1, 0})

    Enum.reduce(approvals, base, fn approval, acc ->
      Map.update(acc, approval.status, 1, &(&1 + 1))
    end)
  end

  defp oldest_pending(approvals) do
    approvals
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.sort_by(&DateTime.to_unix(&1.inserted_at), :asc)
    |> List.first()
  end

  defp approval_command_summary(0, 0, _oldest_pending, nil), do: "No approvals queued."

  defp approval_command_summary(0, resolved, _oldest_pending, nil),
    do: "No pending approvals. #{resolved} resolved decisions remain in the audit trail."

  defp approval_command_summary(pending, resolved, oldest_pending, nil) do
    "Resolve #{pending} pending #{pluralize(pending, "approval")} before agents proceed. Oldest: #{approval_type_label(oldest_pending)}. #{resolved} resolved."
  end

  defp approval_command_summary(_pending, _resolved, _oldest_pending, active_status) do
    "Filtered to #{format_status(active_status)} approvals."
  end

  # The Status segments: All, then one per status with its count (v7 G1).
  defp approval_lanes(counts, active_status) do
    [
      approval_lane(nil, "All", counts |> Map.values() |> Enum.sum(), active_status),
      approval_lane(:pending, "Waiting", Map.get(counts, :pending, 0), active_status),
      approval_lane(:approved, "Approved", Map.get(counts, :approved, 0), active_status),
      approval_lane(:denied, "Denied", Map.get(counts, :denied, 0), active_status),
      approval_lane(:cancelled, "Cancelled", Map.get(counts, :cancelled, 0), active_status)
    ]
  end

  defp approval_lane(status, label, count, active_status) do
    %{
      label: label,
      count: count,
      url: approval_filter_path(status),
      current?: status == active_status
    }
  end

  defp approval_command_actions(pending, active_status) do
    [
      pending > 0 && %{label: "Review pending", url: approval_filter_path(:pending)},
      active_status && %{label: "Clear filter", url: approval_filter_path(nil)},
      %{label: "Activity", url: ~p"/activity?filter_action=approval_created"}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp approval_filter_path(nil), do: ~p"/approvals"
  defp approval_filter_path(status), do: ~p"/approvals?status=#{status}"

  defp parse_status(nil), do: nil
  defp parse_status(""), do: nil

  defp parse_status(status) when is_binary(status) do
    parsed = String.to_existing_atom(status)

    if parsed in Approval.status_values(), do: parsed, else: nil
  rescue
    ArgumentError -> nil
  end

  defp parse_status(status) when status in [:pending, :approved, :denied, :cancelled], do: status
  defp parse_status(_), do: nil

  defp approval_type_label(nil), do: "none"
  defp approval_type_label(approval), do: humanize_type(approval.type)

  @doc """
  Human words for a slug, acronyms in capitals: \"launch_gate\" -> \"Launch gate\",
  \"external_api_access\" -> \"External API access\". The approval pages' titles and payload labels.
  """
  def humanize_type(nil), do: "Approval"

  def humanize_type(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
    |> String.split(" ")
    |> Enum.map_join(" ", &acronym/1)
  end

  @acronyms ~w(api ceo cto id pr url usd)
  defp acronym(word),
    do: if(String.downcase(word) in @acronyms, do: String.upcase(word), else: word)

  defp format_status(nil), do: "All"

  defp format_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  @doc """
  An approval's state as a word and its shape (v7 §1.5): pending reads
  "Waiting for you" only for someone who can resolve it.
  """
  def approval_status(:pending, true), do: {:waiting, "Waiting for you"}
  def approval_status(:pending, _can_resolve), do: {:waiting, "Waiting for a decision"}
  def approval_status(:approved, _can_resolve), do: {:done, "Approved"}
  def approval_status(:denied, _can_resolve), do: {:stopped, "Denied"}
  def approval_status(:cancelled, _can_resolve), do: {:idle, "Cancelled"}
  def approval_status(status, _can_resolve), do: {:idle, format_status(status)}

  def requester_name(%{requested_by: %{name: name}}) when is_binary(name) and name != "",
    do: name

  def requester_name(_approval), do: "unknown"

  def linked_tasks(issues), do: "#{length(issues)} linked #{pluralize(length(issues), "task")}"

  def approval_empty_title(nil), do: "Nothing waiting on you"

  def approval_empty_title(status) do
    "No #{status |> format_status() |> String.downcase()} approvals in this lane"
  end

  def approval_empty_detail(nil) do
    "Nothing to approve. When an agent needs your call — a budget, a deploy, a hire — it lands here."
  end

  def approval_empty_detail(_status) do
    "Clear the filter to see everything, or check Activity if you expected something here."
  end
end
