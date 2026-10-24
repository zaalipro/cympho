defmodule CymphoWeb.InboxLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.Approvals
  alias Cympho.Agents
  alias Cympho.Finances
  alias Cympho.Inbox
  alias Cympho.IssueThreadInteractions
  alias Cympho.OwnerAttention
  alias Cympho.Orchestrator.Dispatcher
  alias CymphoWeb.Live.ReviewChanges
  alias CymphoWeb.NextStep
  alias CymphoWeb.TeamRail
  alias Cympho.Issues.HumanReview

  # "all" is the explicit unified feed; missing status defaults to "action"
  # (Needs you = full OwnerAttention set, reviews included) so Simple first
  # paint matches the nav badge and stays decision-first, not noise-first.
  @statuses ~w(action unread read dismissed archived review all)
  @default_status "action"

  # The r3 kind filter (build-spec §4), in the owner's order: param, label,
  # and the owner kinds it holds (a company stopped at its limit is a problem).
  @kinds [
    {"problem", "Problems", [:problem, :stopped]},
    {"question", "Questions", [:question]},
    {"review", "Reviews", [:review]},
    {"approval", "Approvals", [:approval]}
  ]
  @row_words %{
    stopped: "Spending",
    problem: "Problem",
    question: "Question",
    review: "Review",
    approval: "Approval"
  }
  @row_icons %{
    stopped: "i-stop",
    problem: "i-stop",
    question: "i-question",
    review: "i-doc-check",
    approval: "i-shield"
  }
  @row_tiles %{stopped: :problem, problem: :problem, question: :question}
  @decision_words %{
    answered: "Answered",
    accepted: "Accepted",
    declined: "Declined",
    sent_back: "Sent back",
    cancelled: "Cancelled"
  }

  @impl true
  def mount(_params, _session, socket) do
    company_id =
      if socket.assigns[:current_company], do: socket.assigns.current_company.id, else: nil

    agents = if company_id, do: Agents.list_agents_by_company(company_id), else: []

    socket =
      socket
      |> assign(:page_title, "Inbox")
      |> assign(:review_changes, nil)
      |> assign(:agents, agents)
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:subscribed_agent_id, nil)
      |> assign(:current_status, @default_status)
      |> assign(:digest_density, "compact")
      |> assign(:infinite_scroll, %{})
      |> assign(:inbox_counts, %{})
      |> assign(:agent_counts, %{})
      |> assign(:inbox_command, empty_inbox_command())
      |> assign(:inbox_action_queue, [])
      |> assign(:owner_attention_items, [])
      |> assign(:can_resolve_approvals, can_resolve_approvals?(socket))
      |> assign(:runtime_enabled?, Dispatcher.enabled?())
      |> assign(:kind, nil)
      |> assign(:item_param, nil)
      |> assign(:decided_open, false)
      |> assign(:kind_segments, [])
      |> assign(:next_item, nil)
      |> assign(:inbox_rows, [])
      |> assign(:inbox_shown, 0)
      |> assign(:inbox_total, 0)
      |> assign(:agent_names, %{})
      |> assign(:spending, nil)
      |> assign(:decisions, [])

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
      |> assign(:kind, normalize_kind(params["kind"]))
      |> assign(:item_param, params["item"])
      |> assign(:decided_open, params["decided"] == "open")
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

  def handle_info({:owner_attention_changed, company_id}, socket) do
    if socket.assigns[:current_company] && socket.assigns.current_company.id == company_id do
      # Keep nav badge parity with Needs you when review wakes land while Inbox is open.
      # UserAuth's owner_attention hook also updates these assigns (cont for this view).
      count =
        min(99, OwnerAttention.unresolved_count(company_id, socket.assigns[:current_user]))

      {:noreply,
       socket
       |> assign(:nav_inbox_count, count)
       |> assign(:inbox_badge_count, count)
       |> load_inbox()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({event, _payload}, socket)
      when event in [
             :approval_created,
             :approval_resolved,
             :approval_cancelled,
             :approvals_cancelled_for_issue,
             :board_approval_created,
             :board_approval_resolved,
             :board_approval_cancelled,
             :board_vote_cast
           ] do
    {:noreply, load_inbox(socket)}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "run_status", payload: payload}, socket) do
    selected_agent_id = socket.assigns[:selected_agent_id]
    for_selected? = selected_agent_id == "all" or payload[:agent_id] == selected_agent_id

    toast =
      case payload[:status] do
        "completed" -> {"Agent completed a run", "success"}
        "failed" -> {"Agent run failed", "error"}
        "cancelled" -> {"Agent run cancelled", "warning"}
        _ -> nil
      end

    socket =
      if for_selected? && toast do
        {message, type} = toast

        push_event(socket, "toast", %{
          message: message,
          type: type,
          key: "run_#{payload[:resource_id]}"
        })
      else
        socket
      end

    socket = load_inbox(socket)

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

  def handle_event("approve_approval", %{"approval_id" => approval_id}, socket) do
    resolve_approval(socket, approval_id, :approved, "Approved from Inbox")
  end

  def handle_event("deny_approval", %{"approval_id" => approval_id}, socket) do
    resolve_approval(socket, approval_id, :denied, "Denied from Inbox")
  end

  def handle_event("resolve_interaction", %{"id" => id, "status" => status}, socket) do
    resolve_interaction(socket, id, status)
  end

  def handle_event("respond_questions", params, socket) do
    respond_questions(socket, params)
  end

  def handle_event("resume_agent", %{"id" => id}, socket) do
    with %{id: company_id} <- socket.assigns[:current_company],
         {:ok, agent} <- Agents.get_company_agent(company_id, id),
         {:ok, agent} <- Agents.resume_agent(agent) do
      {:noreply,
       socket
       |> load_inbox()
       |> push_event("toast", %{message: "#{agent.name} can take new work.", type: "success"})}
    else
      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not resume that agent.", type: "error"})}
    end
  end

  def handle_event("dismiss_budget_incident", %{"incident_id" => incident_id}, socket) do
    dismiss_budget_incident(socket, incident_id)
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
    handle_review_action(socket, issue_id, wake_id)
  end

  def handle_event(
        "request_review_changes",
        %{"issue_id" => issue_id, "wake_id" => wake_id},
        socket
      ) do
    ReviewChanges.open(socket, issue_id, wake_id)
  end

  def handle_event("cancel_review_changes", _params, socket) do
    {:noreply, assign(socket, :review_changes, nil)}
  end

  def handle_event("submit_review_changes", params, socket) do
    ReviewChanges.submit(socket, params, &load_inbox/1, "Sent back to engineering for changes.")
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
  # matches the active filter, otherwise drop it. Attention-backed feeds
  # (all/action/review) include pseudo-items, so reload them to preserve
  # ordering and issue-level deduplication.
  defp apply_inbox_change(socket, updated, opts \\ []) do
    if socket.assigns[:current_status] in [nil, "all", "action", "review"] do
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
      status when status in [nil, "all"] -> true
      status -> item.status == status
    end
  end

  defp handle_review_action(socket, issue_id, wake_id) do
    with %{issue: issue} when not is_nil(issue) <-
           Enum.find(
             socket.assigns.owner_attention_items,
             &(&1.issue_id == issue_id and Map.get(&1, :kind) == :review_queue)
           ),
         {:ok, _} <- ReviewChanges.decide(socket, issue, :approve, wake_id: wake_id) do
      {:noreply,
       socket
       |> put_flash(:info, "Issue approved and closed.")
       |> load_inbox()}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           HumanReview.error_message(reason)
         )}

      _ ->
        {:noreply, put_flash(socket, :error, HumanReview.error_message(:not_found))}
    end
  end

  defp resolve_approval(socket, approval_id, decision, reason) do
    with %{id: company_id} <- socket.assigns[:current_company],
         %{id: user_id} <- socket.assigns[:current_user],
         {:ok, _resolved} <-
           Approvals.resolve_company_approval(company_id, approval_id, decision, %{
             resolved_by_user_id: user_id,
             resolution_reason: reason
           }) do
      message = if decision == :approved, do: "Approval accepted.", else: "Approval denied."

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_inbox()}
    else
      {:error, :forbidden} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Only company owners, admins, and board members can resolve approvals."
         )
         |> load_inbox()}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not resolve this approval.")
         |> load_inbox()}
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

  defp resolve_interaction(socket, id, status) do
    user_id = current_user_id(socket)

    with {:ok, atom_status} <- parse_interaction_status(status),
         {:ok, interaction} <- scoped_interaction(socket, id),
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => atom_status,
             "resolved_by_user_id" => user_id
           }) do
      message =
        case atom_status do
          :accepted -> "Accepted from Inbox."
          :rejected -> "Rejected from Inbox."
          _ -> "Interaction updated."
        end

      {:noreply,
       socket
       |> put_flash(:info, message)
       |> load_inbox()}
    else
      {:error, :stale_target_revision} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "This plan changed after the confirmation was requested. Review the latest revision before confirming it."
         )}

      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Could not resolve this interaction.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Interaction not found.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not resolve this interaction.")}
    end
  end

  # Both the Next step (a numbered option or an own answer) and the Advanced
  # card (a free-text response) post here; NextStep reads either shape.
  defp respond_questions(socket, params) do
    with {:ok, id, answer} <- NextStep.answer_from_params(params),
         {:ok, interaction} <- scoped_interaction(socket, id),
         :ask_user_questions <- interaction.kind,
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => :responded,
             "resolved_by_user_id" => current_user_id(socket),
             "response" => answer
           }) do
      {:noreply,
       socket
       |> load_inbox()
       |> push_event("toast", %{message: "Answer sent.", type: "success"})}
    else
      {:error, :empty} ->
        {:noreply,
         push_event(socket, "toast", %{
           message: "Choose an answer or write your own.",
           type: "error"
         })}

      _ ->
        {:noreply,
         push_event(socket, "toast", %{message: "Could not send this answer.", type: "error"})}
    end
  end

  defp dismiss_budget_incident(socket, incident_id) do
    with %{id: company_id} <- socket.assigns[:current_company],
         {:ok, incident} <- scoped_budget_incident(company_id, incident_id),
         {:ok, _resolved} <- Finances.resolve_budget_incident(incident) do
      OwnerAttention.notify_changed(company_id)

      {:noreply,
       socket
       |> put_flash(:info, "Budget alert dismissed.")
       |> load_inbox()}
    else
      {:error, :enforcement_incomplete} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Hard stop is still active. Raise the limit first, then resume paused agents."
         )
         |> load_inbox()}

      _ ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not dismiss this budget alert.")
         |> load_inbox()}
    end
  end

  defp scoped_interaction(socket, id) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    with true <- is_binary(company_id),
         {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         {:ok, _issue} <- Cympho.Issues.get_company_issue(company_id, interaction.issue_id) do
      {:ok, interaction}
    else
      _ -> {:error, :not_found}
    end
  end

  defp scoped_budget_incident(company_id, incident_id)
       when is_binary(company_id) and is_binary(incident_id) do
    case Finances.get_budget_incident!(incident_id) do
      %{company_id: ^company_id, resolved_at: nil} = incident ->
        {:ok, incident}

      _ ->
        {:error, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
  end

  defp scoped_budget_incident(_company_id, _incident_id), do: {:error, :not_found}

  defp parse_interaction_status(status) when status in ["accepted", "rejected", "responded"] do
    {:ok, String.to_existing_atom(status)}
  end

  defp parse_interaction_status(_status), do: {:error, :invalid_transition}

  defp current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> to_string(id)
      _ -> nil
    end
  end

  defp load_inbox(socket) do
    attention_items = owner_attention_items(socket)
    socket = assign(socket, :owner_attention_items, attention_items)
    all_items = build_all_inbox_items(socket, attention_items)

    socket
    |> assign_inbox_counts(length(all_items))
    |> reset_stream(:inbox_items, &fetch_inbox(socket, &1, all_items))
    |> assign_decisions(attention_items)
  end

  # The r3 Inbox (plan P4): every owner decision of the company in the owner's
  # order, filtered by kind; the `item` param (or the first) opens as the Next
  # step and the rest are closed rows. `item` is looked up in this company's
  # own list, so an id from anywhere else falls back to the first item.
  defp assign_decisions(socket, attention_items) do
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    user = socket.assigns[:current_user]

    items =
      if socket.assigns[:selected_agent_id] in [nil, "all"],
        do: attention_items,
        else: owner_attention_items(socket, nil)

    counts = OwnerAttention.counts(company_id, user)
    kind = socket.assigns[:kind]

    items =
      items
      |> Enum.filter(&(is_nil(kind) or OwnerAttention.owner_kind(&1) in kind_members(kind)))
      |> OwnerAttention.owner_order()

    open =
      Enum.find(items, &(&1.id == socket.assigns[:item_param])) || List.first(items)

    names = Map.new(socket.assigns[:agents] || [], &{&1.id, &1.name})
    total = if kind, do: kind_count(counts, kind), else: counts.total

    assign(socket,
      kind_segments: kind_segments(socket.assigns, counts),
      next_item: open,
      inbox_rows: items |> List.delete(open) |> Enum.map(&row_view(&1, names, socket.assigns)),
      inbox_shown: length(items),
      inbox_total: total,
      agent_names: names,
      spending:
        if(open && OwnerAttention.owner_kind(open) == :stopped,
          do: TeamRail.spending(company_id)
        ),
      decisions: decisions(company_id, user)
    )
  end

  defp decisions(company_id, user) do
    company_id
    |> OwnerAttention.recent_decisions(user, days: 7)
    |> Enum.map(fn decision ->
      %{
        word: Map.fetch!(@decision_words, decision.action),
        glyph: if(decision.action in [:answered, :accepted], do: :done, else: :idle),
        id: decision.issue.identifier,
        title: decision.issue.title,
        at: Calendar.strftime(decision.at, "%a %-d %b %H:%M")
      }
    end)
  end

  defp kind_members(kind) do
    Enum.find_value(@kinds, [], fn {param, _label, members} -> if param == kind, do: members end)
  end

  defp kind_count(counts, kind),
    do: kind |> kind_members() |> Enum.map(&Map.get(counts.by_kind, &1, 0)) |> Enum.sum()

  # All, then each kind that has an item (or is the current filter).
  defp kind_segments(assigns, counts) do
    kinds =
      @kinds
      |> Enum.map(fn {param, label, _members} ->
        %{
          label: label,
          count: kind_count(counts, param),
          path: r3_path(assigns, kind: param),
          current: assigns[:kind] == param
        }
      end)
      |> Enum.filter(&(&1.count > 0 or &1.current))

    all = %{
      label: "All",
      count: counts.total,
      path: r3_path(assigns, kind: nil),
      current: is_nil(assigns[:kind])
    }

    [all | kinds]
  end

  # One closed Needs-you row: the object in the agent's (or the dataset's)
  # words, its kind, task, person and time, and one verb. Decisions made on
  # this page open in place (`item`); votes and approvals open their page (S7).
  defp row_view(item, names, assigns) do
    owner = OwnerAttention.owner_kind(item)
    issue = item.issue

    %{
      tile: Map.get(@row_tiles, owner, :neutral),
      icon: Map.fetch!(@row_icons, owner),
      word: Map.fetch!(@row_words, owner),
      title: row_title(item),
      meta:
        Enum.reject(
          [
            issue && issue.identifier && {:mono, issue.identifier},
            row_person(item, names),
            item.inserted_at && {:mono, stamp(item.inserted_at)}
          ],
          &(&1 in [nil, false])
        ),
      verb: row_verb(item),
      patch: row_patch(item, assigns),
      navigate: row_navigate(item)
    }
  end

  defp row_title(%{kind: :agent_paused, summary: summary}) when is_binary(summary), do: summary

  defp row_title(%{kind: :interaction, interaction_kind: :ask_user_questions, questions: [q]}),
    do: q.question

  defp row_title(%{kind: :interaction, summary: summary}) when is_binary(summary), do: summary

  defp row_title(%{kind: :review_queue, issue: issue}),
    do: "Ready for your review: #{issue.title}"

  defp row_title(%{kind: :human_action, issue: %{title: title}}), do: title
  defp row_title(item), do: item.title

  defp row_person(%{kind: :review_queue, issue: issue} = item, names),
    do: Map.get(names, issue.assignee_id) || agent_name(item)

  defp row_person(item, _names), do: agent_name(item)

  defp agent_name(%{agent: %{name: name}}) when is_binary(name), do: name
  defp agent_name(_item), do: nil

  defp row_verb(%{kind: :agent_paused, title: title}), do: title
  defp row_verb(%{kind: :interaction, interaction_kind: :ask_user_questions}), do: "Answer"
  defp row_verb(%{kind: :interaction}), do: "Decide"
  defp row_verb(%{kind: :review_queue}), do: "Review"
  defp row_verb(%{kind: :board_approval}), do: "Open vote"
  defp row_verb(%{kind: :budget_incident}), do: "Open Spending"
  defp row_verb(_item), do: "Open"

  defp row_navigate(%{kind: kind, target_path: path}) when kind in [:board_approval, :approval],
    do: path <> "?from=/inbox"

  defp row_navigate(%{kind: :budget_incident}), do: "/costs"
  defp row_navigate(_item), do: nil

  defp row_patch(%{kind: kind}, _assigns)
       when kind in [:board_approval, :approval, :budget_incident],
       do: nil

  defp row_patch(item, assigns), do: r3_path(assigns, item: item.id)

  # The r3 links keep the Advanced view's own params (status, agent, density).
  defp r3_path(assigns, overrides) do
    query =
      [
        kind: Keyword.get(overrides, :kind, assigns[:kind]),
        item: Keyword.get(overrides, :item),
        status: if(assigns[:current_status] != @default_status, do: assigns[:current_status]),
        agent_id:
          if(assigns[:selected_agent_id] not in [nil, "all"], do: assigns[:selected_agent_id]),
        density: if(assigns[:digest_density] == "detailed", do: "detailed")
      ]
      |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)

    if query == [], do: "/inbox", else: "/inbox?" <> URI.encode_query(query)
  end

  # A clock time within the last day, else the day: "04:12", "Mon 19 Oct".
  defp stamp(%DateTime{} = at) do
    if DateTime.diff(DateTime.utc_now(), at, :hour) < 24,
      do: Calendar.strftime(at, "%H:%M"),
      else: Calendar.strftime(at, "%a %-d %b")
  end

  defp stamp(_at), do: nil

  defp normalize_kind(kind) do
    if Enum.any?(@kinds, fn {param, _label, _members} -> param == kind end), do: kind
  end

  @doc "Nothing needs the owner: the Inbox all clear opens what they decided recently."
  def all_clear(assigns) do
    ~H"""
    <.next_step>
      <:problem>
        <.problem_card title="Nothing needs you">
          <:eyebrow>All clear</:eyebrow>
          <p class="obj">Decisions appear here as soon as an agent asks.</p>
        </.problem_card>
      </:problem>
      <:resolution>
        <.ink_card heading="Recent decisions">
          <.ink_note>Shows what you answered, accepted and approved in the last 7 days.</.ink_note>
          <.ink_foot verb="open">
            <:primary>
              <.primary_pill patch="/inbox?decided=open">See recent decisions</.primary_pill>
            </:primary>
          </.ink_foot>
        </.ink_card>
      </:resolution>
    </.next_step>
    """
  end

  attr :row, :map, required: true
  attr :n, :integer, required: true

  # NextStep's row with the Inbox's own title and a verb that can open in place.
  defp inbox_row(assigns) do
    ~H"""
    <.needs_row
      id={"ib#{@n}"}
      kind={@row.tile}
      icon={@row.icon}
      title={@row.title}
      verb={@row.verb}
      patch={@row.patch}
      navigate={@row.navigate}
    >
      {@row.word}
      <%= for part <- @row.meta do %>
        <span aria-hidden="true"> · </span>
        <%= case part do %>
          <% {:mono, text} -> %>
            <span class="mono">{text}</span>
          <% text -> %>
            {text}
        <% end %>
      <% end %>
    </.needs_row>
    """
  end

  defp fetch_inbox(socket, cursor), do: fetch_inbox(socket, cursor, nil)

  defp fetch_inbox(socket, cursor, all_items) do
    agent_id = socket.assigns[:selected_agent_id]
    status = socket.assigns[:current_status]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    attention_items = socket.assigns[:owner_attention_items] || []

    cond do
      status in [nil, "all"] ->
        capped_page(all_items || build_all_inbox_items(socket, attention_items))

      status == "review" ->
        capped_page(Enum.filter(attention_items, &(&1.kind == :review_queue)))

      # Needs you = full OwnerAttention set (reviews included) so Simple default
      # matches the nav badge / unresolved_count membership.
      status == "action" ->
        capped_page(attention_items)

      agent_id == "all" and company_id ->
        opts = [limit: 100, status: status]
        capped_page(Inbox.list_recent_for_company(company_id, opts))

      agent_id in [nil, "", "all"] ->
        capped_page([])

      true ->
        opts = [after: cursor, status: status]
        Inbox.list_inbox_for_agent_page(agent_id, opts)
    end
  end

  # The "all" and "review" modes are bounded previews, not paginated feeds.
  defp capped_page(items) do
    %Cympho.Pagination.Page{entries: items, next_cursor: nil, has_more?: false}
  end

  defp assign_inbox_counts(socket, all_count \\ nil) do
    agent_id = socket.assigns[:selected_agent_id]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    attention_items = socket.assigns[:owner_attention_items] || []

    counts =
      cond do
        agent_id == "all" and company_id -> Inbox.status_counts_for_company(company_id)
        agent_id in [nil, "", "all"] -> %{}
        true -> Inbox.status_counts_for_agent(agent_id)
      end

    counts =
      counts
      |> Map.put("review", Enum.count(attention_items, &(&1.kind == :review_queue)))
      |> Map.put("action", length(attention_items))
      |> Map.put("all", all_count || length(build_all_inbox_items(socket, attention_items)))

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
      detail: "Nothing is waiting on you here.",
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
    action_item = first_action_item(socket)
    nudge_item = List.first(nudge_items)
    review_item = first_review_queue_item(socket)

    command =
      cond do
        action_count > 0 and action_item ->
          %{
            tone: :urgent,
            badge: "Needs action",
            heading: "Handle your assigned blockers and decisions",
            detail:
              "#{action_count} #{pluralize(action_count, "item")} need#{if action_count == 1, do: "s"} your decision before work can keep moving.",
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
            heading: "Reviews waiting on you",
            detail:
              "#{review_count} #{pluralize(review_count, "delivery")} waiting for your approve or request-changes call.",
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
            heading: "Catch up on unread",
            detail:
              "#{unread_count} unread #{pluralize(unread_count, "item")} in #{inbox_scope_label(socket.assigns.selected_agent_id, socket.assigns.selected_agent)}.",
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
            badge: "Set aside",
            heading: "Things you set aside",
            detail:
              "#{deferred_count} dismissed or archived #{pluralize(deferred_count, "item")} — worth a quick look now and then.",
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
        "Decisions, approvals, and failed work waiting for you.",
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
        "Reviews",
        review_count,
        "Deliveries waiting for your approve or request-changes call.",
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
        "Unread",
        unread_count,
        "New updates from your agents.",
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
        "Set aside",
        deferred_count,
        "Things you dismissed or archived.",
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
    "Nothing is waiting on a launch or missing evidence."
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
    socket.assigns[:owner_attention_items]
    |> List.wrap()
    |> Enum.find(&(&1.kind == :review_queue))
  end

  defp first_action_item(socket) do
    socket.assigns[:owner_attention_items]
    |> List.wrap()
    |> List.first()
  end

  defp build_all_inbox_items(socket, attention_items) do
    agent_id = socket.assigns[:selected_agent_id]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id

    persisted_items =
      cond do
        agent_id == "all" and company_id ->
          Inbox.list_recent_for_company(company_id, limit: 100)

        agent_id in [nil, "", "all"] ->
          []

        true ->
          Inbox.list_inbox_for_agent(agent_id, limit: 100)
      end

    attention_issue_ids =
      attention_items
      |> Enum.map(& &1.issue_id)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    persisted_items =
      Enum.reject(persisted_items, &MapSet.member?(attention_issue_ids, &1.issue_id))

    (attention_items ++ persisted_items)
    |> Enum.sort_by(&unified_inbox_sort_key/1)
  end

  defp unified_inbox_sort_key(item) do
    severity_rank = %{critical: 0, high: 1, medium: 2, low: 3}
    rank = Map.get(severity_rank, Map.get(item, :severity), 4)

    {rank, -inbox_item_timestamp(item), to_string(Map.get(item, :id, ""))}
  end

  defp inbox_item_timestamp(%{inserted_at: %DateTime{} = timestamp}) do
    DateTime.to_unix(timestamp, :microsecond)
  end

  defp inbox_item_timestamp(_item), do: 0

  defp review_nudge_items(socket) do
    socket
    |> preview_items_for_command()
    |> Enum.filter(& &1.review_nudge)
  end

  defp owner_attention_items(socket, agent_id \\ :selected) do
    current_user = socket.assigns[:current_user]
    company_id = socket.assigns[:current_company] && socket.assigns.current_company.id
    agent_id = if agent_id == :selected, do: socket.assigns[:selected_agent_id], else: agent_id

    if is_binary(company_id) and current_user do
      opts =
        if is_binary(agent_id) and agent_id != "all", do: [agent_id: agent_id], else: []

      OwnerAttention.list_items(company_id, current_user, opts)
    else
      []
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

  defp inbox_item_label(%{kind: kind, title: title})
       when kind in [:approval, :board_approval, :interaction, :failed_run, :budget_incident] and
              is_binary(title),
       do: title

  defp inbox_item_label(%{issue: %{identifier: identifier, title: title}}) do
    [identifier, title]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp inbox_item_label(%{issue: %{title: title}}), do: title
  defp inbox_item_label(_item), do: "Inbox item"

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
  defp normalize_status(_), do: @default_status

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
    case Map.fetch(counts, "all") do
      {:ok, count} ->
        count

      :error ->
        @statuses
        |> Enum.map(&count_for(counts, &1))
        |> Enum.sum()
    end
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
  defp status_filter_label("all"), do: "All"
  defp status_filter_label("action"), do: "Needs my action"
  defp status_filter_label("review"), do: "Awaiting review"
  defp status_filter_label(status), do: String.capitalize(status)

  defp status_dot("action"), do: "bg-text-primary"
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
      Map.get(item, :kind) in [:approval, :board_approval, :interaction] -> :decision
      Map.get(item, :kind) == :failed_run -> :failure
      Map.get(item, :kind) == :budget_incident -> :spend
      Map.get(item, :review_nudge) -> :evidence
      item.status == "unread" -> :unread
      item.status in ["dismissed", "archived"] -> :deferred
      true -> :update
    end
  end

  defp kind_icon(:human_action), do: "hero-flag-mini"
  defp kind_icon(:review), do: "hero-check-badge-mini"
  defp kind_icon(:decision), do: "hero-shield-check-mini"
  defp kind_icon(:failure), do: "hero-exclamation-triangle-mini"
  defp kind_icon(:spend), do: "hero-currency-dollar-mini"
  defp kind_icon(:evidence), do: "hero-bolt-mini"
  defp kind_icon(:unread), do: "hero-inbox-arrow-down-mini"
  defp kind_icon(:deferred), do: "hero-archive-box-mini"
  defp kind_icon(_), do: "hero-envelope-open-mini"

  defp kind_tile_class(:human_action), do: "border-brand/30 bg-brand/15 text-brand"
  defp kind_tile_class(:review), do: "border-brand/25 bg-brand/10 text-brand"
  defp kind_tile_class(:decision), do: "border-violet-500/25 bg-violet-500/10 text-violet-200"
  defp kind_tile_class(:failure), do: "border-rose-500/30 bg-rose-500/10 text-rose-200"
  defp kind_tile_class(:spend), do: "border-amber-500/30 bg-amber-500/10 text-amber-200"
  defp kind_tile_class(:evidence), do: "border-amber-500/25 bg-amber-500/10 text-amber-300"
  defp kind_tile_class(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp kind_tile_class(_), do: "border-border bg-surface text-text-quaternary"

  defp kind_chip_label(:human_action), do: "Needs you"
  defp kind_chip_label(:review), do: "Your review"
  defp kind_chip_label(:decision), do: "Your decision"
  defp kind_chip_label(:failure), do: "Run needs attention"
  defp kind_chip_label(:spend), do: "Spend needs attention"
  defp kind_chip_label(:unread), do: "Unread"
  defp kind_chip_label(_), do: nil

  defp kind_chip_class(:human_action), do: "border-brand/30 bg-brand/10 text-brand"
  defp kind_chip_class(:review), do: "border-brand/25 bg-brand/10 text-brand"

  defp kind_chip_class(:decision),
    do: "border-violet-500/25 bg-violet-500/10 text-violet-200"

  defp kind_chip_class(:failure), do: "border-rose-500/30 bg-rose-500/10 text-rose-200"
  defp kind_chip_class(:spend), do: "border-amber-500/30 bg-amber-500/10 text-amber-200"
  defp kind_chip_class(:unread), do: "border-blue-500/25 bg-blue-500/10 text-blue-300"
  defp kind_chip_class(_), do: "border-border bg-surface text-text-tertiary"

  defp empty_state_heading(nil), do: "You're caught up"
  defp empty_state_heading("all"), do: "You're caught up"
  defp empty_state_heading("action"), do: "Nothing needs you"
  defp empty_state_heading("unread"), do: "You're caught up"
  defp empty_state_heading("review"), do: "Review queue is clear"
  defp empty_state_heading("read"), do: "Nothing read yet"
  defp empty_state_heading("dismissed"), do: "Nothing set aside"
  defp empty_state_heading("archived"), do: "Archive is empty"
  defp empty_state_heading(_), do: "You're caught up"

  defp status_tab_class(current, status) do
    current_key = if current in [nil, "all"] and status in [nil, "all"], do: status, else: current

    active? =
      cond do
        status in [nil, "all"] -> current in [nil, "all"]
        true -> current_key == status
      end

    if active? do
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

  defp issue_description(%{description: description}) when is_binary(description) do
    description
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 180)
  end

  defp issue_description(_), do: nil

  defp target_agent_name(%{agent: %{name: name}}, _selected_agent)
       when is_binary(name) and name != "",
       do: name

  defp target_agent_name(%{target_user: %{name: name}}, _selected_agent)
       when is_binary(name) and name != "",
       do: name

  defp target_agent_name(%{target_label_text: label}, _selected_agent)
       when is_binary(label) and label != "",
       do: label

  defp target_agent_name(%{issue: %{assignee: %{name: name}}}, _selected_agent)
       when is_binary(name) and name != "",
       do: name

  defp target_agent_name(%{issue: %{assigned_role: role}}, _selected_agent)
       when not is_nil(role) do
    role
    |> Cympho.Agents.Agent.normalize_role()
    |> Kernel.||(role)
    |> Cympho.Agents.Agent.role_label()
  end

  defp target_agent_name(_item, _selected_agent), do: "the team"

  defp issue_link(issue) when is_nil(issue), do: "#"
  defp issue_link(issue), do: ~p"/issues/#{issue.id}"

  defp owner_decision_label(item), do: item.target_label || "Open details"

  defp owner_decision_item?(item) do
    Map.get(item, :kind) in [
      :approval,
      :board_approval,
      :interaction,
      :failed_run,
      :budget_incident
    ]
  end

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
