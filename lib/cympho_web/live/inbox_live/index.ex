defmodule CymphoWeb.InboxLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Inbox
  alias Cympho.Agents
  alias Cympho.Issues

  @statuses ~w(action unread read dismissed archived review)

  @impl true
  def mount(_params, _session, socket) do
    company_id =
      if socket.assigns[:current_company], do: socket.assigns.current_company.id, else: nil

    agents = if company_id, do: Agents.list_agents_by_company(company_id), else: []

    socket =
      socket
      |> assign(:page_title, "Inbox")
      |> assign(:agents, agents)
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:subscribed_agent_id, nil)
      |> assign(:current_status, nil)
      |> assign(:digest_density, "compact")
      |> assign(:infinite_scroll, %{})
      |> assign(:inbox_counts, %{})
      |> assign(:agent_counts, %{})
      |> assign(:inbox_command, empty_inbox_command())
      |> assign(:inbox_action_queue, [])

    if connected?(socket) do
      if socket.assigns.selected_agent_id do
        Inbox.subscribe(socket.assigns.selected_agent_id)
      end

      if socket.assigns[:current_company] do
        CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)
      end
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    status = normalize_status(params["status"])
    digest_density = normalize_digest_density(params["density"])

    agent_id =
      params["agent_id"]
      |> normalize_agent_id()
      |> authorized_agent_id(socket)

    socket =
      socket
      |> assign(:current_status, status)
      |> assign(:digest_density, digest_density)
      |> assign(:selected_agent_id, agent_id)
      |> assign(:selected_agent, selected_agent(socket.assigns.agents, agent_id))
      |> maybe_subscribe_to_agent()
      |> load_inbox()

    {:noreply, socket}
  end

  @impl true
  def handle_info({:inbox_updated, state}, socket) do
    {:noreply, apply_inbox_change(socket, state)}
  end

  def handle_info({:inbox_created, state}, socket) do
    {:noreply, apply_inbox_change(socket, state, at: 0)}
  end

  def handle_info({:inbox_bulk_updated, _agent_id}, socket) do
    {:noreply, load_inbox(socket)}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    selected_agent_id = socket.assigns[:selected_agent_id]

    socket =
      if selected_agent_id == "all" or payload[:agent_id] == selected_agent_id do
        {message, type} =
          case payload do
            %{new_status: "completed"} -> {"Agent completed a run", "success"}
            %{new_status: "failed"} -> {"Agent run failed", "error"}
            %{new_status: "cancelled"} -> {"Agent run cancelled", "warning"}
            _ -> {"Agent run status changed", "info"}
          end

        push_event(socket, "toast", %{
          message: message,
          type: type,
          key: "run_#{payload[:run_id]}"
        })
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info(msg, socket) do
    require Logger
    Logger.warning("Unhandled message in InboxLive.Index: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl true
  def handle_event("mark_read", params, socket) do
    inbox_action(socket, params, &Inbox.mark_read/2)
  end

  def handle_event("mark_unread_read", _params, socket) do
    case mark_unread_read_for_scope(socket) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> put_flash(:info, "No unread inbox items to mark as read.")
         |> load_inbox()}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, marked_read_message(count))
         |> load_inbox()}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to access this inbox scope")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not update inbox items")}
    end
  end

  def handle_event("dismiss", params, socket) do
    inbox_action(socket, params, &Inbox.dismiss/2)
  end

  def handle_event("archive", params, socket) do
    inbox_action(socket, params, &Inbox.archive/2)
  end

  def handle_event("restore", params, socket) do
    inbox_action(socket, params, &Inbox.restore/2)
  end

  def handle_event("filter_status", %{"status" => status}, socket) do
    {:noreply, push_patch(socket, to: build_url(socket, %{"status" => status}))}
  end

  def handle_event("next-page", _params, socket) do
    {:reply, %{}, load_next(socket, :inbox_items, &fetch_inbox(socket, &1))}
  end

  def handle_event(
        "approve_review",
        %{"issue_id" => issue_id, "wake_id" => wake_id},
        socket
      ) do
    handle_review_action(socket, issue_id, wake_id, :done, "Issue approved and closed.")
  end

  def handle_event(
        "request_review_changes",
        %{"issue_id" => issue_id, "wake_id" => wake_id},
        socket
      ) do
    handle_review_action(
      socket,
      issue_id,
      wake_id,
      :todo,
      "Sent back to engineering for changes."
    )
  end

  def handle_event("select_agent", %{"agent_id" => "all"}, socket) do
    socket =
      socket
      |> assign(:selected_agent_id, "all")
      |> maybe_subscribe_to_agent()
      |> load_inbox()

    {:noreply, push_patch(socket, to: build_url(socket, %{"agent_id" => "all"}))}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    case authorize_agent_access(agent_id, socket) do
      {:ok, _agent} ->
        socket =
          socket
          |> assign(:selected_agent_id, agent_id)
          |> maybe_subscribe_to_agent()
          |> load_inbox()

        {:noreply, push_patch(socket, to: build_url(socket, %{"agent_id" => agent_id}))}

      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to access this agent's inbox")}
    end
  end

  defp inbox_action(socket, %{"issue_id" => issue_id} = params, fun) do
    agent_id = Map.get(params, "agent_id") || socket.assigns.selected_agent_id

    with {:ok, _agent} <- authorize_agent_access(agent_id, socket),
         {:ok, updated} <- fun.(issue_id, agent_id) do
      {:noreply, apply_inbox_change(socket, updated)}
    else
      {:error, :unauthorized} ->
        {:noreply,
         put_flash(socket, :error, "You don't have permission to access this agent's inbox")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Inbox entry not found")}
    end
  end

  defp mark_unread_read_for_scope(socket) do
    agent_id = socket.assigns.selected_agent_id
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    cond do
      agent_id == "all" and company_id ->
        Inbox.mark_unread_read_for_company(company_id)

      agent_id in [nil, "", "all"] ->
        {:error, :unauthorized}

      true ->
        with {:ok, _agent} <- authorize_agent_access(agent_id, socket) do
          Inbox.mark_unread_read_for_agent(agent_id)
        end
    end
  end

  # Update just the affected row instead of resetting the whole stream (which
  # discards scrolled-in pages and the scroll position). Recompute counts, then
  # keep the row (in place, or prepended for new items) when its status still
  # matches the active filter, otherwise drop it. The bounded "review" feed is
  # wake-driven, so fall back to a full reload there.
  defp apply_inbox_change(socket, updated, opts \\ []) do
    if socket.assigns[:current_status] == "review" do
      load_inbox(socket)
    else
      socket = assign_inbox_counts(socket)
      item = Inbox.preload_item(updated)

      if inbox_item_visible?(socket, item) do
        stream_insert(socket, :inbox_items, item, opts)
      else
        stream_delete(socket, :inbox_items, item)
      end
    end
  end

  defp inbox_item_visible?(socket, item) do
    case socket.assigns[:current_status] do
      nil -> true
      status -> item.status == status
    end
  end

  defp handle_review_action(socket, issue_id, wake_id, target_status, ok_message) do
    with {:ok, issue} <- scoped_get_issue(socket, issue_id),
         {:ok, _} <- transition_for_review(issue, target_status),
         :ok <- consume_wake_if_present(wake_id) do
      {:noreply,
       socket
       |> put_flash(:info, ok_message)
       |> load_inbox()}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not complete review action: #{inspect(reason)}"
         )}
    end
  end

  # `transition_issue_with_review_gates/3` runs the same quality gates an
  # agent's approve_issue action hits, so a human approving from the inbox
  # gets the same enforcement.
  defp transition_for_review(issue, :done) do
    Cympho.Issues.transition_issue_with_review_gates(issue, :done, nil)
  end

  defp transition_for_review(issue, :todo) do
    Cympho.Issues.transition_issue(issue, :todo)
  end

  defp consume_wake_if_present(nil), do: :ok
  defp consume_wake_if_present(""), do: :ok

  defp consume_wake_if_present(wake_id) do
    case Cympho.Wakes.get_agent_wake(wake_id) do
      {:ok, wake} ->
        _ = Cympho.Wakes.consume_wake(wake)
        :ok

      _ ->
        :ok
    end
  end

  defp scoped_get_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Cympho.Issues.get_company_issue(company_id, issue_id)
      _ -> Cympho.Issues.get_issue(issue_id)
    end
  end

  defp load_inbox(socket) do
    socket
    |> assign_inbox_counts()
    |> reset_stream(:inbox_items, &fetch_inbox(socket, &1))
  end

  defp fetch_inbox(socket, cursor) do
    agent_id = socket.assigns[:selected_agent_id]
    status = socket.assigns[:current_status]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    cond do
      status == "review" ->
        capped_page(build_review_queue_items(agent_id, company_id))

      status == "action" ->
        capped_page(build_human_action_items(socket))

      agent_id == "all" and company_id ->
        opts = [limit: 100] ++ if(status, do: [status: status], else: [])
        capped_page(Inbox.list_recent_for_company(company_id, opts))

      agent_id in [nil, "", "all"] ->
        capped_page([])

      true ->
        opts = [after: cursor] ++ if(status, do: [status: status], else: [])
        Inbox.list_inbox_for_agent_page(agent_id, opts)
    end
  end

  # The "all" and "review" modes are bounded previews, not paginated feeds.
  defp capped_page(items) do
    %Cympho.Pagination.Page{entries: items, next_cursor: nil, has_more?: false}
  end

  defp assign_inbox_counts(socket) do
    agent_id = socket.assigns[:selected_agent_id]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    counts =
      cond do
        agent_id == "all" and company_id -> Inbox.status_counts_for_company(company_id)
        agent_id in [nil, "", "all"] -> %{}
        true -> Inbox.status_counts_for_agent(agent_id)
      end

    counts =
      counts
      |> Map.put("review", review_queue_count(agent_id, company_id))
      |> Map.put("action", human_action_count(socket))

    agent_counts = if company_id, do: Inbox.counts_by_agent_for_company(company_id), else: %{}

    socket
    |> assign(:inbox_counts, normalize_counts(counts))
    |> assign(:agent_counts, agent_counts)
    |> assign_inbox_command()
  end

  defp assign_inbox_command(socket) do
    nudge_items = review_nudge_items(socket)

    socket
    |> assign(:inbox_command, build_inbox_command(socket, nudge_items))
    |> assign(:inbox_action_queue, build_inbox_action_queue(socket, nudge_items))
  end

  defp empty_inbox_command do
    %{
      tone: :clear,
      badge: "Clear",
      heading: "Inbox is clear",
      detail:
        "No handoffs, review decisions, or unread agent signals need attention in this scope.",
      action_label: "Open issues",
      action_path: "/issues",
      focus_label: nil,
      focus_detail: nil,
      action_count: 0,
      unread_count: 0,
      review_count: 0,
      nudge_count: 0,
      deferred_count: 0,
      total_count: 0
    }
  end

  defp build_inbox_command(socket, nudge_items) do
    counts = socket.assigns.inbox_counts
    unread_count = count_for(counts, "unread")
    action_count = count_for(counts, "action")
    review_count = count_for(counts, "review")
    deferred_count = count_for(counts, "dismissed") + count_for(counts, "archived")
    total = total_count(counts)
    action_item = first_human_action_item(socket)
    nudge_item = List.first(nudge_items)
    review_item = first_review_queue_item(socket)

    command =
      cond do
        action_count > 0 and action_item ->
          %{
            tone: :urgent,
            badge: "Needs action",
            heading: "Handle your assigned blockers",
            detail:
              "#{action_count} human #{pluralize(action_count, "task")} need your decision before agents can move cleanly.",
            action_label: "Open my action queue",
            action_path:
              inbox_url(
                socket.assigns.selected_agent_id,
                socket.assigns.current_status,
                socket.assigns.digest_density,
                %{status: "action"}
              ),
            focus_label: inbox_item_label(action_item),
            focus_detail: target_agent_name(action_item, socket.assigns.selected_agent)
          }

        review_count > 0 and review_item ->
          %{
            tone: :review,
            badge: "Review due",
            heading: "Decide review queue",
            detail:
              "#{review_count} review #{pluralize(review_count, "decision")} need approve, changes, or evidence follow-up.",
            action_label: "Open review queue",
            action_path:
              inbox_url(
                socket.assigns.selected_agent_id,
                socket.assigns.current_status,
                socket.assigns.digest_density,
                %{
                  status: "review"
                }
              ),
            focus_label: inbox_item_label(review_item),
            focus_detail: target_agent_name(review_item, socket.assigns.selected_agent)
          }

        nudge_item && nudge_item.review_nudge && nudge_item.review_nudge.target_path ->
          %{
            tone: :attention,
            badge: nudge_item.review_nudge.label || "Launch needed",
            heading: "Start runtime before evidence",
            detail: nudge_item.review_nudge.summary,
            action_label: nudge_item.review_nudge.target_label || "Open launch checklist",
            action_path: nudge_item.review_nudge.target_path,
            focus_label: inbox_item_label(nudge_item),
            focus_detail: target_agent_name(nudge_item, socket.assigns.selected_agent)
          }

        nudge_item && nudge_item.review_nudge ->
          %{
            tone: :attention,
            badge: nudge_item.review_nudge.label || "Evidence needed",
            heading: "Repair evidence request",
            detail: nudge_item.review_nudge.summary,
            action_label: "Open issue",
            action_path: issue_link(nudge_item.issue),
            focus_label: inbox_item_label(nudge_item),
            focus_detail: target_agent_name(nudge_item, socket.assigns.selected_agent)
          }

        unread_count > 0 ->
          %{
            tone: :unread,
            badge: "Unread",
            heading: "Clear unread handoffs",
            detail:
              "#{unread_count} unread #{pluralize(unread_count, "item")} need triage in #{inbox_scope_label(socket.assigns.selected_agent_id, socket.assigns.selected_agent)}.",
            action_label: "Show unread",
            action_path:
              inbox_url(
                socket.assigns.selected_agent_id,
                socket.assigns.current_status,
                socket.assigns.digest_density,
                %{
                  status: "unread"
                }
              ),
            focus_label:
              inbox_scope_label(socket.assigns.selected_agent_id, socket.assigns.selected_agent),
            focus_detail: "#{total} total #{pluralize(total, "item")}"
          }

        deferred_count > 0 ->
          %{
            tone: :deferred,
            badge: "Deferred",
            heading: "Review deferred inbox work",
            detail:
              "#{deferred_count} dismissed or archived #{pluralize(deferred_count, "item")} may need cleanup before the next operating cycle.",
            action_label: "Show dismissed",
            action_path:
              inbox_url(
                socket.assigns.selected_agent_id,
                socket.assigns.current_status,
                socket.assigns.digest_density,
                %{
                  status: "dismissed"
                }
              ),
            focus_label:
              inbox_scope_label(socket.assigns.selected_agent_id, socket.assigns.selected_agent),
            focus_detail: "#{deferred_count} deferred"
          }

        true ->
          empty_inbox_command()
      end

    command
    |> Map.put(:action_count, action_count)
    |> Map.put(:unread_count, unread_count)
    |> Map.put(:review_count, review_count)
    |> Map.put(:nudge_count, length(nudge_items))
    |> Map.put(:deferred_count, deferred_count)
    |> Map.put(:total_count, total)
  end

  defp build_inbox_action_queue(socket, nudge_items) do
    counts = socket.assigns.inbox_counts
    unread_count = count_for(counts, "unread")
    action_count = count_for(counts, "action")
    review_count = count_for(counts, "review")
    deferred_count = count_for(counts, "dismissed") + count_for(counts, "archived")
    nudge_count = length(nudge_items)
    nudge_item = List.first(nudge_items)

    [
      inbox_queue_item(
        :human_action,
        "Needs my action",
        action_count,
        "Issues assigned directly to you, not mixed into agent notification noise.",
        "Open my queue",
        inbox_url(
          socket.assigns.selected_agent_id,
          socket.assigns.current_status,
          socket.assigns.digest_density,
          %{status: "action"}
        ),
        if(action_count > 0, do: :urgent, else: :clear)
      ),
      inbox_queue_item(
        :review,
        "Review decisions",
        review_count,
        "Approve, request changes, or inspect missing review evidence.",
        "Open reviews",
        inbox_url(
          socket.assigns.selected_agent_id,
          socket.assigns.current_status,
          socket.assigns.digest_density,
          %{status: "review"}
        ),
        if(review_count > 0, do: :urgent, else: :clear)
      ),
      inbox_queue_item(
        :evidence,
        "Runtime / evidence",
        nudge_count,
        nudge_queue_summary(nudge_item),
        nudge_queue_action_label(nudge_item),
        nudge_queue_action_path(socket, nudge_item),
        if(nudge_count > 0, do: :attention, else: :clear)
      ),
      inbox_queue_item(
        :unread,
        "Unread handoffs",
        unread_count,
        "Read new agent handoffs before they age into stale work.",
        "Show unread",
        inbox_url(
          socket.assigns.selected_agent_id,
          socket.assigns.current_status,
          socket.assigns.digest_density,
          %{status: "unread"}
        ),
        if(unread_count > 0, do: :unread, else: :clear)
      ),
      inbox_queue_item(
        :deferred,
        "Deferred cleanup",
        deferred_count,
        "Review dismissed or archived signals before the next operating cycle.",
        "Show dismissed",
        inbox_url(
          socket.assigns.selected_agent_id,
          socket.assigns.current_status,
          socket.assigns.digest_density,
          %{status: "dismissed"}
        ),
        if(deferred_count > 0, do: :deferred, else: :clear)
      )
    ]
  end

  defp inbox_queue_item(key, label, count, summary, action_label, action_path, tone) do
    %{
      key: key,
      label: label,
      count: count,
      summary: summary,
      action_label: action_label,
      action_path: action_path,
      tone: tone,
      state_label: inbox_queue_state_label(tone)
    }
  end

  defp inbox_queue_state_label(:urgent), do: "Act now"
  defp inbox_queue_state_label(:attention), do: "Needs evidence"
  defp inbox_queue_state_label(:unread), do: "Read"
  defp inbox_queue_state_label(:deferred), do: "Cleanup"
  defp inbox_queue_state_label(:clear), do: "Clear"

  defp nudge_queue_summary(%{review_nudge: %{summary: summary}}) when summary not in [nil, ""] do
    summary
  end

  defp nudge_queue_summary(_nudge_item) do
    "No runtime launch or review-evidence repair request is waiting."
  end

  defp nudge_queue_action_label(%{review_nudge: %{target_label: label}})
       when label not in [nil, ""] do
    label
  end

  defp nudge_queue_action_label(%{review_nudge: %{target_path: path}})
       when path not in [nil, ""] do
    "Open launch checklist"
  end

  defp nudge_queue_action_label(_nudge_item), do: "Open issues"

  defp nudge_queue_action_path(_socket, %{review_nudge: %{target_path: path}})
       when path not in [nil, ""] do
    path
  end

  defp nudge_queue_action_path(_socket, %{issue: issue}) when not is_nil(issue) do
    issue_link(issue)
  end

  defp nudge_queue_action_path(_socket, _nudge_item), do: "/issues"

  defp first_review_queue_item(socket) do
    socket.assigns.selected_agent_id
    |> review_scope(socket.assigns[:current_company] && socket.assigns.current_company.id)
    |> Cympho.Wakes.list_review_queue(limit: 1)
    |> case do
      [%{wake: wake, issue: issue} | _] ->
        %{
          id: wake.id,
          kind: :review_queue,
          wake_id: wake.id,
          issue: issue,
          issue_id: issue.id,
          agent: wake.agent,
          agent_id: wake.agent_id,
          status: "review",
          review_nudge: nil,
          inserted_at: wake.inserted_at
        }

      [] ->
        nil
    end
  end

  defp first_human_action_item(socket) do
    socket
    |> build_human_action_items()
    |> List.first()
  end

  defp review_nudge_items(socket) do
    socket
    |> preview_items_for_command()
    |> Enum.filter(& &1.review_nudge)
  end

  defp build_human_action_items(socket) do
    current_user = socket.assigns[:current_user]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case current_user do
      %{id: user_id} when is_binary(company_id) and is_binary(user_id) ->
        company_id
        |> Issues.list_human_action_issues(user_id, limit: 100)
        |> Enum.map(fn issue ->
          %{
            id: "human-action-#{issue.id}",
            kind: :human_action,
            issue: issue,
            issue_id: issue.id,
            agent: nil,
            agent_id: nil,
            target_user: current_user,
            status: "action",
            review_nudge: nil,
            inserted_at: issue.updated_at || issue.inserted_at
          }
        end)

      _ ->
        []
    end
  end

  defp human_action_count(socket) do
    current_user = socket.assigns[:current_user]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    case current_user do
      %{id: user_id} when is_binary(company_id) and is_binary(user_id) ->
        Issues.human_action_count(company_id, user_id)

      _ ->
        0
    end
  end

  defp preview_items_for_command(socket) do
    agent_id = socket.assigns.selected_agent_id
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    cond do
      agent_id == "all" and company_id ->
        Inbox.list_recent_for_company(company_id, limit: 100)

      agent_id in [nil, "", "all"] ->
        []

      true ->
        Inbox.list_inbox_for_agent(agent_id, limit: 100)
    end
  end

  defp inbox_item_label(%{issue: %{identifier: identifier, title: title}}) do
    [identifier, title]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp inbox_item_label(%{issue: %{title: title}}), do: title
  defp inbox_item_label(_item), do: "Inbox item"

  # Returns the "Awaiting my review" pseudo-items: wake-driven entries that
  # share the inbox row shape so the existing template can render them.
  # `kind: :review_queue` tags each so we can swap action buttons.
  defp build_review_queue_items(agent_id, company_id) do
    scope = review_scope(agent_id, company_id)

    scope
    |> Cympho.Wakes.list_review_queue(limit: 100)
    |> Enum.map(fn %{wake: wake, issue: issue} ->
      %{
        id: wake.id,
        kind: :review_queue,
        wake: wake,
        wake_id: wake.id,
        issue: issue,
        issue_id: issue.id,
        agent: wake.agent,
        agent_id: wake.agent_id,
        status: "review",
        review_nudge: nil,
        inserted_at: wake.inserted_at
      }
    end)
  end

  defp review_queue_count(agent_id, company_id) do
    scope = review_scope(agent_id, company_id)
    scope |> Cympho.Wakes.list_review_queue(limit: 200) |> length()
  end

  defp review_scope(agent_id, company_id) do
    cond do
      agent_id in [nil, "", "all"] and is_binary(company_id) -> {:company, company_id}
      is_binary(agent_id) -> {:agent, agent_id}
      true -> {:agent, nil}
    end
  end

  defp build_url(socket, overrides) do
    status = Map.get(overrides, "status", socket.assigns.current_status)
    agent_id = Map.get(overrides, "agent_id", socket.assigns.selected_agent_id)
    digest_density = Map.get(overrides, "density", socket.assigns.digest_density)

    query =
      %{
        status: status,
        agent_id: agent_id,
        density: if(digest_density == "detailed", do: digest_density)
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.into(%{})

    ~p"/inbox?#{query}"
  end

  defp inbox_url(selected_agent_id, status, density, overrides) do
    status = Map.get(overrides, :status, status)
    agent_id = Map.get(overrides, :agent_id, selected_agent_id)
    density = Map.get(overrides, :density, density)

    query =
      %{
        status: status,
        agent_id: agent_id,
        density: if(density == "detailed", do: density)
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, ""] end)
      |> Enum.into(%{})

    ~p"/inbox?#{query}"
  end

  defp authorize_agent_access(nil, _socket), do: {:error, :unauthorized}
  defp authorize_agent_access("all", _socket), do: {:ok, :all}

  defp authorize_agent_access(agent_id, socket) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    if company_id do
      case Agents.get_company_agent(company_id, agent_id) do
        {:ok, agent} -> {:ok, agent}
        {:error, :not_found} -> {:error, :unauthorized}
      end
    else
      {:error, :unauthorized}
    end
  end

  defp maybe_subscribe_to_agent(socket) do
    agent_id = socket.assigns[:selected_agent_id]
    subscribed_id = socket.assigns[:subscribed_agent_id]

    if connected?(socket) && agent_id && agent_id != "all" && agent_id != subscribed_id do
      if subscribed_id && subscribed_id != "all" do
        Inbox.unsubscribe(subscribed_id)
      end

      Inbox.subscribe(agent_id)
      assign(socket, :subscribed_agent_id, agent_id)
    else
      socket
    end
  end

  defp normalize_status(status) when status in @statuses, do: status
  defp normalize_status(_), do: nil

  defp normalize_digest_density("compact"), do: "compact"
  defp normalize_digest_density("detailed"), do: "detailed"
  defp normalize_digest_density(_), do: "compact"

  defp normalize_agent_id("all"), do: "all"
  defp normalize_agent_id(agent_id) when is_binary(agent_id) and agent_id != "", do: agent_id
  defp normalize_agent_id(_), do: "all"

  defp authorized_agent_id("all", _socket), do: "all"

  defp authorized_agent_id(agent_id, socket) do
    case authorize_agent_access(agent_id, socket) do
      {:ok, _agent} -> agent_id
      {:error, :unauthorized} -> "all"
    end
  end

  defp selected_agent(_agents, "all"), do: nil
  defp selected_agent(agents, agent_id), do: Enum.find(agents, &(&1.id == agent_id))

  defp normalize_counts(counts) do
    Map.merge(%{"unread" => 0, "read" => 0, "dismissed" => 0, "archived" => 0}, counts)
  end

  defp count_for(counts, status), do: Map.get(counts, status, 0)

  defp total_count(counts) do
    @statuses
    |> Enum.map(&count_for(counts, &1))
    |> Enum.sum()
  end

  defp agent_option_label(agent, agent_counts) do
    counts = Map.get(agent_counts, agent.id, %{})
    total = total_count(normalize_counts(counts))
    unread = Map.get(counts, "unread", 0)

    cond do
      unread > 0 -> "#{agent.name} (#{unread} unread)"
      total > 0 -> "#{agent.name} (#{total})"
      true -> agent.name
    end
  end

  defp inbox_scope_label("all", _agent), do: "All agents"
  defp inbox_scope_label(_agent_id, %{name: name}), do: name
  defp inbox_scope_label(_agent_id, _agent), do: "Selected agent"

  defp marked_read_message(1), do: "Marked 1 unread inbox item as read."
  defp marked_read_message(count), do: "Marked #{count} unread inbox items as read."

  defp status_filter_label(nil), do: "All"
  defp status_filter_label("action"), do: "Needs my action"
  defp status_filter_label("review"), do: "Awaiting review"
  defp status_filter_label(status), do: String.capitalize(status)

  defp status_dot("action"), do: "bg-white"
  defp status_dot("unread"), do: "bg-blue-400"
  defp status_dot("read"), do: "bg-slate-400"
  defp status_dot("dismissed"), do: "bg-amber-400"
  defp status_dot("archived"), do: "bg-text-quaternary"
  defp status_dot("review"), do: "bg-brand"
  defp status_dot(_), do: "bg-slate-500"

  # One kind per row so the eye can filter by shape: who needs me (:human_action),
  # what I must decide (:review), what's blocked on evidence (:evidence), what's
  # new (:unread), and what's already settled (:update / :deferred).
  defp item_kind(item) do
    cond do
      Map.get(item, :kind) == :human_action -> :human_action
      Map.get(item, :kind) == :review_queue -> :review
      Map.get(item, :review_nudge) -> :evidence
      item.status == "unread" -> :unread
      item.status in ["dismissed", "archived"] -> :deferred
      true -> :update
    end
  end

  defp kind_icon(:human_action), do: "hero-flag-mini"
  defp kind_icon(:review), do: "hero-check-badge-mini"
  defp kind_icon(:evidence), do: "hero-bolt-mini"
  defp kind_icon(:unread), do: "hero-inbox-arrow-down-mini"
  defp kind_icon(:deferred), do: "hero-archive-box-mini"
  defp kind_icon(_), do: "hero-envelope-open-mini"

  defp kind_tile_class(:human_action), do: "border-brand/30 bg-brand/15 text-brand"
  defp kind_tile_class(:review), do: "border-brand/25 bg-brand/10 text-brand"
  defp kind_tile_class(:evidence), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp kind_tile_class(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp kind_tile_class(_), do: "border-border bg-surface text-text-quaternary"

  defp kind_chip_label(:human_action), do: "Needs you"
  defp kind_chip_label(:review), do: "Your review"
  defp kind_chip_label(:unread), do: "Unread"
  defp kind_chip_label(_), do: nil

  defp kind_chip_class(:human_action), do: "border-brand/30 bg-brand/10 text-brand"
  defp kind_chip_class(:review), do: "border-brand/25 bg-brand/10 text-brand"
  defp kind_chip_class(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp kind_chip_class(_), do: "border-border bg-surface text-text-tertiary"

  defp empty_state_heading(nil), do: "Inbox zero"
  defp empty_state_heading("action"), do: "Nothing needs you"
  defp empty_state_heading("unread"), do: "All caught up"
  defp empty_state_heading("review"), do: "Review queue is clear"
  defp empty_state_heading("read"), do: "Nothing read yet"
  defp empty_state_heading("dismissed"), do: "Nothing set aside"
  defp empty_state_heading("archived"), do: "Archive is empty"
  defp empty_state_heading(_), do: "Inbox zero"

  defp empty_state_detail(nil) do
    "Nothing needs you here right now. Agent handoffs, review requests, and issue updates will surface as the autonomous workflow runs."
  end

  defp empty_state_detail("action"),
    do: "No issues are waiting on your decision. Agents keep moving on their own from here."

  defp empty_state_detail("unread"),
    do: "Every handoff has been read. New agent handoffs land here first."

  defp empty_state_detail("review"),
    do: "No deliveries are waiting on your approve-or-request-changes call."

  defp empty_state_detail("read"),
    do: "Items you have read stay here until you dismiss or archive them."

  defp empty_state_detail("dismissed"),
    do: "Dismissed items wait here in case you want them back."

  defp empty_state_detail("archived"),
    do: "Archived items are kept here for reference."

  defp empty_state_detail(_), do: empty_state_detail(nil)

  defp status_tab_class(current, status) do
    if current == status do
      "border-brand bg-brand/15 text-text-primary"
    else
      "border-border bg-surface text-text-tertiary hover:border-border-hover hover:bg-surface-hover hover:text-text-secondary"
    end
  end

  # Archive-keeping filters stay quieter than the triage lanes: borderless
  # until active so the row reads as "work first, filing second".
  defp cleanup_tab_class(current, status) do
    if current == status do
      "border-brand bg-brand/15 text-text-primary"
    else
      "border-transparent bg-transparent text-text-quaternary hover:border-border hover:bg-surface hover:text-text-secondary"
    end
  end

  defp priority_badge_class(:critical), do: "border-brand/25 bg-brand/15 text-brand"
  defp priority_badge_class(:high), do: "border-amber-400/25 bg-amber-400/10 text-amber-300"
  defp priority_badge_class(:medium), do: "border-yellow-500/20 bg-yellow-500/10 text-yellow-300"
  defp priority_badge_class(:low), do: "border-slate-500/20 bg-slate-500/10 text-slate-300"
  defp priority_badge_class(_), do: "border-border bg-surface text-text-quaternary"

  defp issue_status_label(status) when is_atom(status) do
    status |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp issue_status_label(status) when is_binary(status) do
    status |> String.replace("_", " ") |> String.capitalize()
  end

  defp issue_status_label(_), do: "Unknown"

  defp priority_label(priority) when is_atom(priority),
    do: priority |> to_string() |> String.capitalize()

  defp priority_label(priority) when is_binary(priority), do: String.capitalize(priority)
  defp priority_label(_), do: "No priority"

  defp issue_description(%{description: description}) when is_binary(description) do
    description
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp issue_description(_), do: nil

  defp target_agent_name(%{agent: %{name: name}}, _selected_agent) when is_binary(name), do: name

  defp target_agent_name(%{target_user: %{name: name}}, _selected_agent) when is_binary(name),
    do: name

  defp target_agent_name(_item, %{name: name}) when is_binary(name), do: name
  defp target_agent_name(_item, _selected_agent), do: "Unknown agent"

  defp issue_link(issue) when is_nil(issue), do: "#"
  defp issue_link(issue), do: ~p"/issues/#{issue.id}"

  defp pluralize(1, word), do: word
  defp pluralize(_, word), do: word <> "s"

  defp inbox_command_badge(:review), do: "border-brand/25 bg-brand/10 text-brand"
  defp inbox_command_badge(:attention), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp inbox_command_badge(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp inbox_command_badge(:deferred), do: "border-slate-500/25 bg-slate-500/10 text-slate-300"

  defp inbox_command_badge(:clear),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp inbox_command_badge(_), do: "border-border bg-surface text-text-tertiary"

  defp inbox_command_action(:review),
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp inbox_command_action(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300 hover:bg-amber-500/15"

  defp inbox_command_action(:unread),
    do: "border-blue-500/25 bg-blue-500/10 text-blue-300 hover:bg-blue-500/15"

  defp inbox_command_action(:deferred),
    do: "border-slate-500/25 bg-slate-500/10 text-slate-300 hover:bg-slate-500/15"

  defp inbox_command_action(:clear),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300 hover:bg-emerald-500/15"

  defp inbox_command_action(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp inbox_queue_card_class(:urgent), do: "border-l-2 border-l-brand/70"
  defp inbox_queue_card_class(:attention), do: "border-l-2 border-l-amber-400/70"
  defp inbox_queue_card_class(:unread), do: "border-l-2 border-l-blue-400/70"
  defp inbox_queue_card_class(:deferred), do: "border-l-2 border-l-slate-400/70"
  defp inbox_queue_card_class(_), do: ""

  defp inbox_queue_count_class(:urgent), do: "text-brand"
  defp inbox_queue_count_class(:attention), do: "text-amber-300"
  defp inbox_queue_count_class(:unread), do: "text-blue-300"
  defp inbox_queue_count_class(:deferred), do: "text-slate-300"
  defp inbox_queue_count_class(_), do: "text-text-primary"

  defp inbox_queue_badge_class(:urgent), do: "border-brand/25 bg-brand/10 text-brand"

  defp inbox_queue_badge_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-300"

  defp inbox_queue_badge_class(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"

  defp inbox_queue_badge_class(:deferred),
    do: "border-slate-500/25 bg-slate-500/10 text-slate-300"

  defp inbox_queue_badge_class(:clear),
    do: "border-emerald-500/25 bg-emerald-500/10 text-emerald-300"

  defp inbox_queue_badge_class(_), do: "border-border bg-surface text-text-tertiary"

  # Humane "3h ago"-style age keeps rows scannable; the exact stamp lives in
  # the title tooltip via `full_timestamp/1`.
  defp relative_time_label(nil), do: nil

  defp relative_time_label(dt) do
    seconds = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds < 7 * 86_400 -> "#{div(seconds, 86_400)}d ago"
      true -> Calendar.strftime(dt, "%b %d")
    end
  end

  defp full_timestamp(nil), do: nil
  defp full_timestamp(dt), do: Calendar.strftime(dt, "%b %d, %Y %H:%M UTC")
end
