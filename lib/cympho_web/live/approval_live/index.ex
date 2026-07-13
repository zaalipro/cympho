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
       page_title: "Approvals",
       status_filter: nil,
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
         {:ok, _approval} <- Approvals.get_company_approval(company_id, id),
         {:ok, _resolved} <-
           Approvals.resolve_approval(id, decision, %{
             resolved_by_user_id: current_user_id(socket),
             resolution_reason: reason
           }) do
      {:noreply,
       socket
       |> put_flash(:info, if(decision == :approved, do: "Approved", else: "Denied"))
       |> reload_approvals()}
    else
      _ -> {:noreply, put_flash(socket, :error, "Could not resolve approval")}
    end
  end

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
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
      linked_issue_count: linked_issue_count(approvals),
      oldest_pending: oldest_pending,
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
      linked_issue_count: 0,
      oldest_pending: nil,
      summary: "No approvals queued.",
      lanes: approval_lanes(%{}, nil),
      actions: [
        %{
          label: "All approvals",
          url: ~p"/approvals",
          tone: :primary,
          icon: "hero-queue-list-mini"
        },
        %{
          label: "Activity",
          url: ~p"/activity?filter_action=approval_created",
          tone: :neutral,
          icon: "hero-clock-mini"
        }
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

  defp linked_issue_count(approvals) do
    approvals
    |> Enum.flat_map(& &1.issues)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> length()
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

  defp approval_lanes(counts, active_status) do
    [
      approval_lane(:pending, "Pending", counts, active_status),
      approval_lane(:approved, "Approved", counts, active_status),
      approval_lane(:denied, "Denied", counts, active_status),
      approval_lane(:cancelled, "Cancelled", counts, active_status)
    ]
  end

  defp approval_lane(status, label, counts, active_status) do
    count = Map.get(counts, status, 0)

    %{
      status: status,
      label: label,
      count: count,
      url: approval_filter_path(status),
      active?: status == active_status,
      state: approval_lane_state(status, count)
    }
  end

  defp approval_lane_state(:pending, 0), do: "Clear"
  defp approval_lane_state(:pending, _count), do: "Needs decision"
  defp approval_lane_state(:approved, _count), do: "Approved path"
  defp approval_lane_state(:denied, _count), do: "Rejected path"
  defp approval_lane_state(:cancelled, _count), do: "Stopped path"

  defp approval_command_actions(pending, active_status) do
    [
      pending > 0 &&
        %{
          label: "Review pending",
          url: approval_filter_path(:pending),
          tone: :primary,
          icon: "hero-bolt-mini"
        },
      active_status &&
        %{
          label: "Clear filter",
          url: approval_filter_path(nil),
          tone: :neutral,
          icon: "hero-x-mark-mini"
        },
      %{
        label: "Activity",
        url: ~p"/activity?filter_action=approval_created",
        tone: :neutral,
        icon: "hero-clock-mini"
      }
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

  @doc "Human words for a gate slug: \"launch_gate\" -> \"Launch gate\"."
  def humanize_type(nil), do: "Approval"

  def humanize_type(type) when is_binary(type) do
    type
    |> String.replace(["_", "-"], " ")
    |> String.capitalize()
  end

  def approval_age(%DateTime{} = inserted_at) do
    seconds = DateTime.diff(DateTime.utc_now(), inserted_at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "waiting #{div(seconds, 60)}m"
      seconds < 86_400 -> "waiting #{div(seconds, 3600)}h"
      true -> "waiting #{div(seconds, 86_400)}d"
    end
  end

  def approval_age(_), do: nil

  def queue_section_label(nil), do: "Decision queue"
  def queue_section_label(status), do: "#{format_status(status)} approvals"

  defp format_status(nil), do: "All"

  defp format_status(status) do
    status
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp pluralize(1, word), do: word
  defp pluralize(_count, word), do: word <> "s"

  def approval_action_class(:primary) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg bg-primary px-3 text-sm font-510 text-white transition-colors hover:bg-primary-hover"
  end

  def approval_action_class(_tone) do
    "inline-flex h-9 items-center justify-center gap-2 rounded-lg border border-border bg-surface px-3 text-sm font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end

  def approval_lane_class(%{active?: true}) do
    "rounded-lg border border-primary/35 bg-primary/10 px-4 py-3 transition-colors"
  end

  def approval_lane_class(%{count: count}) when count > 0 do
    "rounded-lg border border-border bg-surface-1 px-4 py-3 transition-colors hover:bg-surface-2"
  end

  def approval_lane_class(_lane) do
    "rounded-lg border border-border bg-surface/60 px-4 py-3 transition-colors hover:bg-surface-hover"
  end

  def approval_lane_count_class(%{active?: true}),
    do: "mt-3 font-mono text-2xl font-590 text-primary"

  def approval_lane_count_class(%{count: count}) when count > 0,
    do: "mt-3 font-mono text-2xl font-590 text-text-primary"

  def approval_lane_count_class(_lane),
    do: "mt-3 font-mono text-2xl font-590 text-text-quaternary"

  def approval_row_note(%{status: :pending, issues: issues}) do
    issue_count = length(issues)

    if issue_count > 0 do
      "Blocks #{issue_count} linked #{pluralize(issue_count, "issue")}"
    else
      "Decision needed before the agent proceeds"
    end
  end

  def approval_row_note(%{status: status}) do
    "#{format_status(status)} decision record"
  end

  def approval_row_action_label(:pending), do: "Review decision"
  def approval_row_action_label(_status), do: "View record"

  def approval_row_action_class(_status) do
    "inline-flex shrink-0 items-center text-xs font-510 text-text-tertiary underline decoration-border underline-offset-4 transition-colors hover:text-text-primary"
  end

  def approval_card_class(:pending) do
    "rounded-xl border border-brand/30 bg-surface-1 shadow-[inset_2px_0_0_0_var(--color-primary)] transition-colors hover:border-brand/45"
  end

  def approval_card_class(_status) do
    "rounded-lg border border-border/70 bg-surface-1/60 transition-colors hover:border-border-hover hover:bg-subtle"
  end

  def approval_empty_title(nil), do: "Nothing waiting on you"

  def approval_empty_title(status) do
    "No #{status |> format_status() |> String.downcase()} approvals in this lane"
  end

  def approval_empty_detail(nil) do
    "Every gate is clear and the company is running itself. When an agent needs a budget, deployment, hiring, or external-access call, the decision packet will land here."
  end

  def approval_empty_detail(_status) do
    "Clear the filter to inspect the full decision trail, or open Activity if you expected an approval event."
  end

  def approval_empty_action_class(:primary) do
    "inline-flex h-8 items-center justify-center rounded-lg bg-primary px-3 text-xs font-510 text-white transition-colors hover:bg-primary-hover"
  end

  def approval_empty_action_class(_tone) do
    "inline-flex h-8 items-center justify-center rounded-lg border border-border bg-surface px-3 text-xs font-510 text-text-secondary transition-colors hover:bg-surface-hover hover:text-text-primary"
  end

  @doc """
  Whether to show the calm "nothing waiting on you" strip above a queue
  that still holds resolved history: no pending work, no active filter,
  but at least one settled record below.
  """
  def all_clear_with_history?(command, status_filter) do
    is_nil(status_filter) && command.pending_count == 0 &&
      Enum.any?(command.counts, fn {status, count} -> status != :pending && count > 0 end)
  end
end
