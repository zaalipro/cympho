defmodule CymphoWeb.IssueLive.Show do
  use CymphoWeb, :live_view
  use CymphoWeb, :html

  import CymphoWeb.IssueLive.Show.Helpers

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.DeliveryBriefReadiness
  alias Cympho.Documents
  alias Cympho.HeartbeatEngine
  alias Cympho.Issues
  alias Cympho.Issues.AutoAssignment
  alias Cympho.IssueBriefReadiness
  alias Cympho.IssueReadStates
  alias Cympho.IssueThreadInteractions
  alias Cympho.Orchestrator
  alias Cympho.ReviewNudges
  alias Cympho.ToolCallTraces
  alias Cympho.WorkProducts

  @timeline_filters ~w(signal comments runs artifacts all)
  @repo_delivery_roles Cympho.Agents.Agent.pr_delivery_roles() |> Enum.map(&Atom.to_string/1)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
      Comments.subscribe(socket.assigns.current_company.id)
      CymphoWeb.Events.subscribe_to_runs(socket.assigns.current_company.id)
      Documents.subscribe(socket.assigns.current_company.id)
    end

    # Subscribe to read state updates if user is logged in
    current_user = socket.assigns[:current_user]

    if current_user do
      IssueReadStates.subscribe(current_user.id)
    end

    case get_scoped_issue(socket, id) do
      {:ok, issue} ->
        # Auto-mark as read for the current user
        if current_user do
          IssueReadStates.ensure_read(current_user.id, issue.id)
        end

        comment_changeset = blank_comment_changeset()
        runs = HeartbeatEngine.list_runs_for_issue(issue.id)
        interactions = IssueThreadInteractions.list_interactions(issue.id)
        work_products = WorkProducts.list_work_products(issue.id)
        child_issues = Issues.list_child_issues(issue.id)
        child_tree = Issues.list_descendants_tree(issue.id, 4)
        child_health_cards = child_issue_health_cards(child_issues)
        pending_wake = load_pending_wake_for_issue(issue)
        tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: issue.id)
        timeline = build_timeline(issue, runs, interactions, work_products, tool_call_traces)
        documents = Documents.list_documents(issue.id)

        {:ok,
         assign(socket,
           issue: issue,
           route_issue_id: issue.id,
           comment_changeset: comment_changeset,
           comment_form: to_form(comment_changeset),
           comment_templates: comment_templates(),
           work_product_form: blank_work_product_form(),
           show_work_product_form: false,
           agents: list_idle_agents(socket),
           all_agents: list_company_agents(socket),
           orchestrator_enabled?: Cympho.Orchestrator.Dispatcher.enabled?(),
           show_agent_panel: false,
           editing: nil,
           description_draft: nil,
           description_return_to: nil,
           assignee_search: "",
           runs: runs,
           interactions: interactions,
           work_products: work_products,
           child_issues: child_issues,
           child_tree: child_tree,
           child_health_cards: child_health_cards,
           pending_wake: pending_wake,
           tool_call_traces: tool_call_traces,
           timeline: timeline,
           timeline_filter: "signal",
           scrolled_to_bottom: true,
           expanded_traces: %{},
           documents: documents,
           selected_document: nil,
           show_revisions: false,
           revisions: [],
           selected_revision_diff: nil,
           rollback_blocker: nil,
           gate_clean_url: nil
         )}

      {:error, :not_found} ->
        {:ok, push_navigate(socket, to: ~p"/issues")}
    end
  end

  @impl true
  def handle_params(%{"id" => id} = params, _url, socket) do
    socket =
      socket
      |> apply_action(socket.assigns.live_action, id)
      |> assign_description_return_to(params)
      |> apply_edit_param(params)
      |> apply_gate_param(params)
      |> maybe_clean_gate_url()

    {:noreply, socket}
  end

  defp apply_action(socket, :show, id) do
    case get_scoped_issue(socket, id) do
      {:ok, issue} ->
        socket
        |> assign(:page_title, issue.title)
        |> assign(:issue, issue)
        |> assign(:route_issue_id, issue.id)
        |> assign_child_rollup(issue.id)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Issue not found")
        |> push_navigate(to: ~p"/issues")
    end
  end

  defp apply_action(socket, nil, id) do
    apply_action(socket, :show, id)
  end

  defp apply_edit_param(socket, %{"edit" => "description", "repair" => "owner_brief"}) do
    draft_owner_brief_repair(socket)
  end

  defp apply_edit_param(socket, %{"repair" => "owner_brief"}) do
    draft_owner_brief_repair(socket)
  end

  defp apply_edit_param(socket, %{"edit" => "description"}) do
    assign(socket, editing: "description", description_draft: nil)
  end

  defp apply_edit_param(socket, _params), do: socket

  defp assign_description_return_to(socket, %{"return_to" => return_to} = params) do
    repair_description? =
      params["edit"] == "description" or params["repair"] == "owner_brief"

    assign(
      socket,
      :description_return_to,
      if(repair_description?, do: safe_return_path(return_to))
    )
  end

  defp assign_description_return_to(socket, _params),
    do: assign(socket, :description_return_to, nil)

  defp safe_return_path(return_to) when is_binary(return_to) do
    return_to = URI.decode(return_to)

    cond do
      String.starts_with?(return_to, "//") -> nil
      String.starts_with?(return_to, "/") and not String.contains?(return_to, "://") -> return_to
      true -> nil
    end
  end

  defp safe_return_path(_return_to), do: nil

  defp apply_gate_param(socket, %{"gate" => gate}) when is_binary(gate) do
    case gate do
      "delivery_note" -> apply_gate_action(socket, "delivery_note", "issue-comments")
      "review_comment" -> apply_gate_action(socket, "review_comment", "issue-comments")
      "owner_update" -> apply_gate_action(socket, "owner_update", "issue-comments")
      "verification" -> apply_gate_action(socket, "verification", "issue-agent-panel")
      "work_product" -> apply_gate_action(socket, "work_product", "issue-work-product-form")
      "code_reference" -> apply_gate_action(socket, "code_reference", "issue-github-pr")
      _ -> assign(socket, :gate_clean_url, nil)
    end
  end

  defp apply_gate_param(socket, _params), do: assign(socket, :gate_clean_url, nil)

  defp apply_gate_action(socket, action, anchor) do
    socket
    |> resolve_review_gate(action)
    |> assign(:gate_clean_url, gate_clean_url(socket, anchor))
  end

  defp gate_clean_url(socket, anchor), do: "#{~p"/issues/#{socket.assigns.issue.id}"}##{anchor}"

  defp maybe_clean_gate_url(%{assigns: %{gate_clean_url: clean_url}} = socket)
       when is_binary(clean_url) and clean_url != "" do
    push_event(socket, "issue:replace_url", %{url: clean_url})
  end

  defp maybe_clean_gate_url(socket), do: socket

  defp reopen_for_relaunch(%{status: status} = issue) when status in [:blocked, "blocked"] do
    Issues.update_issue(issue, %{status: :todo})
  end

  defp reopen_for_relaunch(issue), do: {:ok, issue}

  defp notify_dispatcher_if_enabled(%{assigns: %{orchestrator_enabled?: true}}) do
    _ = Cympho.Orchestrator.Dispatcher.poll_now()
    true
  end

  defp notify_dispatcher_if_enabled(_socket), do: false

  defp dispatch_focus_flash(:prioritize, true),
    do: "Issue prioritized and dispatcher notified."

  defp dispatch_focus_flash(:prioritize, false),
    do:
      "Issue prioritized for next dispatch. Copy the focused command from the digest or sidebar and start runtime."

  defp dispatch_focus_flash(:relaunch, true),
    do: "Issue reopened and dispatcher notified for focused relaunch."

  defp dispatch_focus_flash(:relaunch, false),
    do:
      "Issue queued for focused relaunch. Copy the focused command from this issue page and start runtime."

  defp owner_revision_flash(true),
    do: "Owner revision requested and dispatcher notified for focused CEO relaunch."

  defp owner_revision_flash(false),
    do:
      "Owner revision requested and focused CEO relaunch queued. Start runtime from Operations to continue."

  @impl true
  def handle_event("add_comment", %{"comment" => comment_params}, socket) do
    comment_params =
      socket
      |> default_comment_params()
      |> Map.merge(comment_params)
      |> Map.put("issue_id", socket.assigns.issue.id)

    case Comments.create_comment(comment_params) do
      {:ok, _comment} ->
        changeset = blank_comment_changeset()

        {:noreply,
         assign(socket,
           comment_changeset: changeset,
           comment_form: to_form(changeset)
         )}

      {:error, changeset} ->
        {:noreply, assign(socket, comment_changeset: changeset, comment_form: to_form(changeset))}
    end
  end

  @impl true
  def handle_event("use_comment_template", %{"template" => key}, socket) do
    {:noreply, apply_comment_template(socket, key)}
  end

  @impl true
  def handle_event("resolve_review_gate", %{"action" => action}, socket) do
    {:noreply, resolve_review_gate(socket, action)}
  end

  @impl true
  def handle_event("queue_review_nudge", %{"key" => key}, socket) do
    gate_resolution = review_gate_resolution(socket.assigns)

    case ReviewNudges.execute(socket.assigns.issue, key,
           blockers: gate_resolution.blockers,
           agents: socket.assigns.all_agents,
           child_issues: socket.assigns.child_issues,
           actor: socket.assigns[:current_user]
         ) do
      {:ok, %{already_queued?: true} = nudge} ->
        {:noreply,
         socket
         |> refresh_issue_assigns()
         |> put_flash(:info, "Auto-nudge is already queued for #{nudge.agent_name}.")}

      {:ok, nudge} ->
        {:noreply,
         socket
         |> refresh_issue_assigns()
         |> put_flash(:info, "Auto-nudge queued for #{nudge.agent_name}.")}

      {:error, :no_target_agent} ->
        {:noreply, put_flash(socket, :error, "No matching agent is available for that nudge.")}

      {:error, :nudge_not_found} ->
        {:noreply, put_flash(socket, :error, "That review nudge is no longer active.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue nudge: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("queue_contract_nudge", %{"contract" => contract_key}, socket) do
    case ReviewNudges.execute_contract_gap(socket.assigns.issue, contract_key,
           agents: socket.assigns.all_agents,
           runs: socket.assigns.runs,
           work_products: socket.assigns.work_products,
           child_issues: socket.assigns.child_issues,
           actor: socket.assigns[:current_user]
         ) do
      {:ok, %{already_queued?: true} = nudge} ->
        {:noreply,
         socket
         |> refresh_issue_assigns()
         |> put_flash(:info, "Contract nudge is already queued for #{nudge.agent_name}.")}

      {:ok, nudge} ->
        {:noreply,
         socket
         |> refresh_issue_assigns()
         |> put_flash(:info, "Contract nudge queued for #{nudge.agent_name}.")}

      {:error, :no_target_agent} ->
        {:noreply, put_flash(socket, :error, "No matching agent is available for that contract.")}

      {:error, :nudge_not_found} ->
        {:noreply, put_flash(socket, :error, "That prompt contract gap is no longer active.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Failed to queue contract nudge: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("validate_work_product", %{"work_product" => work_product_params}, socket) do
    changeset =
      socket
      |> work_product_attrs(work_product_params)
      |> work_product_changeset()
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :work_product_form, to_work_product_form(changeset))}
  end

  @impl true
  def handle_event("attach_work_product", %{"work_product" => work_product_params}, socket) do
    attrs = work_product_attrs(socket, work_product_params)

    case WorkProducts.create_work_product(attrs) do
      {:ok, _work_product} ->
        {:noreply,
         socket
         |> maybe_rebuild_timeline()
         |> assign(:timeline_filter, "artifacts")
         |> assign(:show_work_product_form, false)
         |> assign(:work_product_form, blank_work_product_form())
         |> put_flash(:info, "Work product attached.")}

      {:error, changeset} ->
        {:noreply,
         assign(socket,
           show_work_product_form: true,
           work_product_form: to_work_product_form(changeset)
         )}
    end
  end

  @impl true
  def handle_event("cancel_work_product", _params, socket) do
    {:noreply,
     assign(socket,
       show_work_product_form: false,
       work_product_form: blank_work_product_form()
     )}
  end

  @impl true
  def handle_event("delete_comment", %{"id" => id}, socket) do
    case scoped_comment(socket, id) do
      {:ok, comment} ->
        _ = Comments.delete_comment(comment)
        {:noreply, socket}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Comment not found")}
    end
  end

  @impl true
  def handle_event("set_timeline_filter", %{"filter" => filter}, socket)
      when filter in @timeline_filters do
    {:noreply, assign(socket, :timeline_filter, filter)}
  end

  def handle_event("set_timeline_filter", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("combobox_status", %{"selected" => status}, socket) when is_binary(status) do
    handle_event("update_status", %{"status" => status}, socket)
  end

  def handle_event("combobox_status", _, socket), do: {:noreply, socket}

  def handle_event("combobox_priority", %{"selected" => priority}, socket)
      when is_binary(priority) do
    handle_event("update_priority", %{"priority" => priority}, socket)
  end

  def handle_event("combobox_priority", _, socket), do: {:noreply, socket}

  def handle_event("combobox_assignee", %{"selected" => nil}, socket) do
    handle_event("unassign_issue", %{}, socket)
  end

  def handle_event("combobox_assignee", %{"selected" => agent_id}, socket)
      when is_binary(agent_id) do
    handle_event("assign_issue", %{"agent_id" => agent_id}, socket)
  end

  @impl true
  def handle_event("update_status", %{"status" => status}, socket) do
    status_atoms = %{
      "backlog" => :backlog,
      "todo" => :todo,
      "in_progress" => :in_progress,
      "in_review" => :in_review,
      "done" => :done,
      "blocked" => :blocked,
      "cancelled" => :cancelled
    }

    case Map.fetch(status_atoms, status) do
      {:ok, status_atom} ->
        update_status_with_review_gates(socket, status_atom, status)

      :error ->
        {:noreply, put_flash(socket, :error, "Invalid status")}
    end
  end

  @impl true
  def handle_event("update_priority", %{"priority" => priority}, socket) do
    priority_atom = try_string_to_priority(priority)

    case priority_atom do
      nil ->
        {:noreply, put_flash(socket, :error, "Invalid priority")}

      atom ->
        case Issues.update_issue(socket.assigns.issue, %{priority: atom}) do
          {:ok, issue} ->
            {:noreply, socket |> assign(issue: issue) |> put_flash(:info, "Priority updated")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update priority")}
        end
    end
  end

  @impl true
  def handle_event("start_editing", %{"field" => "description"}, socket) do
    {:noreply,
     assign(socket, editing: "description", description_draft: nil, description_return_to: nil)}
  end

  @impl true
  def handle_event("start_editing", %{"field" => field}, socket) do
    {:noreply, assign(socket, editing: field, description_draft: nil, description_return_to: nil)}
  end

  @impl true
  def handle_event("cancel_editing", _params, socket) do
    {:noreply, assign(socket, editing: nil, description_draft: nil, description_return_to: nil)}
  end

  @impl true
  def handle_event("draft_owner_brief_repair", _params, socket) do
    {:noreply, draft_owner_brief_repair(socket, flash?: true)}
  end

  @impl true
  def handle_event("draft_delivery_brief_repair", _params, socket) do
    case DeliveryBriefReadiness.evaluate(socket.assigns.issue) do
      %{status: status, repair_scaffold: scaffold} when status in [:thin, :draft] ->
        {:noreply,
         socket
         |> assign(editing: "description", description_draft: scaffold)
         |> put_flash(:info, "Delivery brief scaffold loaded into the description editor.")}

      _readiness ->
        {:noreply, put_flash(socket, :info, "Delivery brief is already ready for dispatch.")}
    end
  end

  @impl true
  def handle_event("save_title", %{"title" => title}, socket) do
    case Issues.update_issue(socket.assigns.issue, %{title: title}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue, editing: nil, description_draft: nil)
         |> put_flash(:info, "Title updated")}

      {:error, _} ->
        message =
          if String.trim(title) == "" do
            "Title cannot be empty"
          else
            "Failed to update title"
          end

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("save_description", %{"description" => description}, socket) do
    return_to = socket.assigns[:description_return_to]

    case Issues.update_issue(socket.assigns.issue, %{description: description}) do
      {:ok, issue} ->
        socket =
          socket
          |> assign(
            issue: issue,
            editing: nil,
            description_draft: nil,
            description_return_to: nil
          )
          |> put_flash(:info, "Description updated")

        if return_to do
          {:noreply, push_navigate(socket, to: return_to)}
        else
          {:noreply, socket}
        end

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update description")}
    end
  end

  @impl true
  def handle_event("update_github_pr_number", %{"github_pr_number" => raw}, socket) do
    pr_number = parse_pr_number(raw)
    attrs = %{github_pr_number: pr_number, github_pr_url: nil}

    case Issues.update_issue(socket.assigns.issue, attrs) do
      {:ok, issue} ->
        {:noreply, audit_issue_pr_quality(socket, issue)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update PR number")}
    end
  end

  @impl true
  def handle_event("check_github_pr_quality", _params, socket) do
    {:noreply, audit_issue_pr_quality(socket, socket.assigns.issue)}
  end

  @impl true
  def handle_event("clear_github_pr_number", _params, socket) do
    attrs = %{
      github_pr_number: nil,
      github_pr_url: nil,
      monitor_state: Issues.clear_pr_quality_monitor_state(socket.assigns.issue.monitor_state)
    }

    case Issues.update_issue(socket.assigns.issue, attrs) do
      {:ok, issue} ->
        {:noreply, assign(socket, issue: %{issue | project: socket.assigns.issue.project})}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to clear PR")}
    end
  end

  @impl true
  def handle_event("search_assignee", %{"q" => q}, socket) do
    {:noreply, assign(socket, assignee_search: q)}
  end

  def handle_event("search_assignee", %{"value" => q}, socket) do
    {:noreply, assign(socket, assignee_search: q)}
  end

  @impl true
  def handle_event("assign_issue", %{"agent_id" => agent_id}, socket) do
    with {:ok, _agent} <- get_scoped_agent(socket, agent_id),
         {:ok, issue} <- Issues.update_issue(socket.assigns.issue, %{assignee_id: agent_id}) do
      {:noreply,
       socket
       |> assign(issue: issue, assignee_search: "")
       |> put_flash(:info, "Assignee updated")}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to assign issue")}
    end
  end

  @impl true
  def handle_event("unassign_issue", _params, socket) do
    case Issues.update_issue(socket.assigns.issue, %{assignee_id: nil}) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(issue: issue)
         |> put_flash(:info, "Assignee removed")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to unassign issue")}
    end
  end

  @impl true
  def handle_event("toggle_agent_panel", _, socket) do
    if socket.assigns.orchestrator_enabled? do
      {:noreply, update(socket, :show_agent_panel, &(!&1))}
    else
      {:noreply, put_flash(socket, :error, "Agent execution is disabled in this runtime")}
    end
  end

  @impl true
  def handle_event("prioritize_dispatch", _params, socket) do
    case Issues.prioritize_for_dispatch(socket.assigns.issue,
           actor: socket.assigns[:current_user]
         ) do
      {:ok, issue} ->
        dispatcher_notified? = notify_dispatcher_if_enabled(socket)

        {:noreply,
         socket
         |> assign(:issue, %{issue | project: socket.assigns.issue.project})
         |> put_flash(:info, dispatch_focus_flash(:prioritize, dispatcher_notified?))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to prioritize issue")}
    end
  end

  @impl true
  def handle_event("clear_dispatch_focus", _params, socket) do
    case Issues.clear_dispatch_focus(socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(:issue, %{issue | project: socket.assigns.issue.project})
         |> put_flash(:info, "Dispatch focus cleared.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to clear dispatch focus")}
    end
  end

  @impl true
  def handle_event("clear_child_dispatch_focus", %{"issue-id" => issue_id}, socket) do
    with true <- child_issue_id?(socket, issue_id),
         {:ok, child_issue} <- get_scoped_issue(socket, issue_id),
         {:ok, _child_issue} <- Issues.clear_dispatch_focus(child_issue) do
      {:noreply,
       socket
       |> assign_child_rollup(socket.assigns.issue.id)
       |> put_flash(:info, "Dispatch focus cleared for child issue.")}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "Failed to clear child dispatch focus")}
    end
  end

  @impl true
  def handle_event("accept_owner_verification", _params, socket) do
    case Issues.accept_owner_verification(socket.assigns.issue,
           actor: socket.assigns[:current_user]
         ) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(:issue, issue)
         |> assign_child_rollup(issue.id)
         |> maybe_rebuild_timeline()
         |> put_flash(:info, "Owner verification accepted and issue closed.")}

      {:error, :blocked_by_active_issues} ->
        {:noreply, put_flash(socket, :error, "Issue is blocked by active issues")}

      {:error, :not_owner_verification} ->
        {:noreply, put_flash(socket, :error, "Issue is not waiting on owner verification.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to accept owner verification.")}
    end
  end

  @impl true
  def handle_event("request_owner_revision", _params, socket) do
    case Issues.request_owner_verification_revision(socket.assigns.issue,
           actor: socket.assigns[:current_user]
         ) do
      {:ok, issue} ->
        dispatcher_notified? = notify_dispatcher_if_enabled(socket)

        {:noreply,
         socket
         |> assign(:issue, issue)
         |> assign_child_rollup(issue.id)
         |> maybe_rebuild_timeline()
         |> put_flash(:info, owner_revision_flash(dispatcher_notified?))}

      {:error, :blocked_by_active_issues} ->
        {:noreply, put_flash(socket, :error, "Issue is blocked by active issues")}

      {:error, :not_owner_verification} ->
        {:noreply, put_flash(socket, :error, "Issue is not waiting on owner verification.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to request CEO revision.")}
    end
  end

  @impl true
  def handle_event("prepare_relaunch", _params, socket) do
    with {:ok, issue} <- reopen_for_relaunch(socket.assigns.issue),
         {:ok, issue} <-
           Issues.prioritize_for_dispatch(issue, actor: socket.assigns[:current_user]) do
      dispatcher_notified? = notify_dispatcher_if_enabled(socket)

      {:noreply,
       socket
       |> assign(:issue, %{issue | project: socket.assigns.issue.project})
       |> put_flash(:info, dispatch_focus_flash(:relaunch, dispatcher_notified?))}
    else
      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to queue focused relaunch")}
    end
  end

  @impl true
  def handle_event("spawn_agent", %{"agent_id" => agent_id}, socket) do
    issue = socket.assigns.issue

    if socket.assigns.orchestrator_enabled? do
      with {:ok, agent} <- get_scoped_agent(socket, agent_id),
           {:ok, checked_out} <- Issues.checkout_issue(issue, agent_id),
           {:ok, _pid} <- Orchestrator.start_and_run(checked_out, agent_id),
           {:ok, _updated_agent} <- Agents.update_agent(agent, %{status: :running}) do
        {:noreply,
         socket
         |> put_flash(:info, "Agent started successfully")
         |> assign(:issue, checked_out)
         |> assign(:show_agent_panel, false)
         |> assign(:agents, list_idle_agents(socket))}
      else
        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to spawn agent: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Agent execution is disabled in this runtime")}
    end
  end

  @impl true
  def handle_event("release_issue", _params, socket) do
    case Issues.release_issue(socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply, assign(socket, issue: issue)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to release issue: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("resolve_interaction", %{"id" => id, "status" => status}, socket) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: to_string(current_user.id), else: nil

    with {:ok, interaction} <- scoped_interaction(socket, id),
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => String.to_existing_atom(status),
             "resolved_by_user_id" => user_id
           }) do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Invalid state transition")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Interaction not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve interaction")}
    end
  end

  @impl true
  def handle_event(
        "respond_questions",
        %{"_id" => id, "response" => response},
        socket
      ) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: to_string(current_user.id), else: nil

    with {:ok, interaction} <- scoped_interaction(socket, id),
         {:ok, _updated} <-
           IssueThreadInteractions.resolve_interaction(interaction, %{
             "status" => :responded,
             "resolved_by_user_id" => user_id,
             "response" => response
           }) do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:error, :invalid_transition} ->
        {:noreply, put_flash(socket, :error, "Invalid state transition")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Interaction not found")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to respond")}
    end
  end

  @impl true
  def handle_event("toggle_trace", %{"id" => id}, socket) do
    expanded_traces = socket.assigns.expanded_traces
    new_state = Map.put(expanded_traces, id, !Map.get(expanded_traces, id, false))
    {:noreply, assign(socket, :expanded_traces, new_state)}
  end

  @impl true
  def handle_event("show_document_revisions", %{"document_key" => key}, socket) do
    case Documents.get_document_by_key(socket.assigns.issue.id, key) do
      {:ok, document} ->
        revisions = Documents.list_revisions(document.id)

        # Check for plan approval binding blocker
        blocker = check_plan_approval_blocker(key, socket.assigns.issue)

        {:noreply,
         assign(socket,
           selected_document: document,
           show_revisions: true,
           revisions: revisions,
           selected_revision_diff: nil,
           rollback_blocker: blocker
         )}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Document not found")}
    end
  end

  @impl true
  def handle_event("hide_revisions", _, socket) do
    {:noreply,
     assign(socket,
       selected_document: nil,
       show_revisions: false,
       revisions: [],
       selected_revision_diff: nil,
       rollback_blocker: nil
     )}
  end

  @impl true
  def handle_event("show_revision_diff", %{"revision_id" => revision_id}, socket) do
    revisions = socket.assigns.revisions

    latest_revision =
      case revisions do
        [first | _] -> first
        [] -> nil
      end

    if latest_revision do
      diff_result = Documents.get_diff(revision_id, latest_revision.id)
      {:noreply, assign(socket, :selected_revision_diff, diff_result)}
    else
      {:noreply, put_flash(socket, :error, "No revisions to compare")}
    end
  end

  @impl true
  def handle_event("hide_revision_diff", _, socket) do
    {:noreply, assign(socket, :selected_revision_diff, nil)}
  end

  @impl true
  def handle_event("restore_revision", %{"revision_id" => revision_id}, socket) do
    if socket.assigns.rollback_blocker do
      {:noreply, put_flash(socket, :error, socket.assigns.rollback_blocker)}
    else
      document = socket.assigns.selected_document

      case Documents.rollback_to_revision(document, revision_id) do
        {:ok, _restored} ->
          # Reload documents and revisions
          documents = Documents.list_documents(socket.assigns.issue.id)
          revisions = Documents.list_revisions(document.id)

          {:noreply,
           socket
           |> put_flash(:info, "Document restored successfully")
           |> assign(
             documents: documents,
             revisions: revisions,
             selected_revision_diff: nil
           )}

        {:error, :pending_approvals} ->
          {:noreply, put_flash(socket, :error, "Cannot restore: issue has pending approvals")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to restore revision")}
      end
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          event: "issue_update",
          payload: %{event_type: :issue_deleted, resource_id: issue_id}
        },
        socket
      ) do
    cond do
      socket.assigns.issue.id == issue_id ->
        {:noreply, push_navigate(socket, to: ~p"/issues")}

      child_issue_id?(socket, issue_id) ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info(
        %Phoenix.Socket.Broadcast{event: "issue_update", payload: %{resource_id: issue_id}},
        socket
      ) do
    case get_scoped_issue(socket, issue_id) do
      {:ok, issue} -> handle_info({:issue_updated, issue}, socket)
      {:error, _} -> {:noreply, socket}
    end
  end

  def handle_info({:issue_updated, updated_issue}, socket) do
    cond do
      socket.assigns.issue.id == updated_issue.id ->
        case get_scoped_issue(socket, updated_issue.id) do
          {:ok, issue} ->
            runs = HeartbeatEngine.list_runs_for_issue(issue.id)

            socket =
              socket
              |> assign(issue: issue, runs: runs)
              |> assign_child_rollup(issue.id)
              |> push_event("toast", %{
                message: "Issue updated by another user",
                type: "info",
                key: "issue_#{issue.id}_updated"
              })

            {:noreply, maybe_rebuild_timeline(socket)}

          {:error, _} ->
            {:noreply, socket}
        end

      updated_issue.parent_id == socket.assigns.issue.id ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:issue_deleted, _deleted_id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/issues")}
  end

  def handle_info({:comment_created, updated_issue}, socket) do
    cond do
      socket.assigns.issue.id == updated_issue.id ->
        case get_scoped_issue(socket, updated_issue.id) do
          {:ok, issue} ->
            socket =
              socket
              |> assign(:issue, issue)
              |> push_event("toast", %{
                message: "New comment added",
                type: "info",
                key: "comment_#{issue.id}_created"
              })

            {:noreply, maybe_rebuild_timeline(socket)}

          {:error, _} ->
            {:noreply, socket}
        end

      updated_issue.parent_id == socket.assigns.issue.id ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:comment_updated, updated_issue}, socket) do
    cond do
      socket.assigns.issue.id == updated_issue.id ->
        case get_scoped_issue(socket, updated_issue.id) do
          {:ok, issue} ->
            socket = assign(socket, :issue, issue)
            {:noreply, maybe_rebuild_timeline(socket)}

          {:error, _} ->
            {:noreply, socket}
        end

      updated_issue.parent_id == socket.assigns.issue.id ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:comment_deleted, updated_issue}, socket) do
    cond do
      socket.assigns.issue.id == updated_issue.id ->
        case get_scoped_issue(socket, updated_issue.id) do
          {:ok, issue} ->
            socket = assign(socket, :issue, issue)
            {:noreply, maybe_rebuild_timeline(socket)}

          {:error, _} ->
            {:noreply, socket}
        end

      updated_issue.parent_id == socket.assigns.issue.id ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:issue_read_state_updated, _issue_id}, socket) do
    # Refresh the issue to update unread indicators
    case get_scoped_issue(socket, socket.assigns.issue.id) do
      {:ok, issue} ->
        {:noreply, assign(socket, :issue, issue)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:new_comment_on_read_issue, _issue_id, _comment_id}, socket) do
    case get_scoped_issue(socket, socket.assigns.issue.id) do
      {:ok, issue} ->
        {:noreply, assign(socket, :issue, issue)}

      {:error, _} ->
        {:noreply, socket}
    end
  end

  def handle_info({:interaction_created, interaction}, socket) do
    if socket.assigns.issue.id == interaction.issue_id do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:interaction_updated, interaction}, socket) do
    if socket.assigns.issue.id == interaction.issue_id do
      interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          interactions,
          socket.assigns.work_products,
          socket.assigns.tool_call_traces
        )

      {:noreply, assign(socket, interactions: interactions, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:work_product_created, work_product}, socket) do
    cond do
      socket.assigns.issue.id == work_product.issue_id ->
        work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

        timeline =
          build_timeline(
            socket.assigns.issue,
            socket.assigns.runs,
            socket.assigns.interactions,
            work_products,
            socket.assigns.tool_call_traces
          )

        {:noreply, assign(socket, work_products: work_products, timeline: timeline)}

      child_issue_id?(socket, work_product.issue_id) ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:work_product_updated, work_product}, socket) do
    cond do
      socket.assigns.issue.id == work_product.issue_id ->
        work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

        timeline =
          build_timeline(
            socket.assigns.issue,
            socket.assigns.runs,
            socket.assigns.interactions,
            work_products,
            socket.assigns.tool_call_traces
          )

        {:noreply, assign(socket, work_products: work_products, timeline: timeline)}

      child_issue_id?(socket, work_product.issue_id) ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:work_product_deleted, issue_id}, socket) do
    cond do
      socket.assigns.issue.id == issue_id ->
        work_products = WorkProducts.list_work_products(socket.assigns.issue.id)

        timeline =
          build_timeline(
            socket.assigns.issue,
            socket.assigns.runs,
            socket.assigns.interactions,
            work_products,
            socket.assigns.tool_call_traces
          )

        {:noreply, assign(socket, work_products: work_products, timeline: timeline)}

      child_issue_id?(socket, issue_id) ->
        {:noreply, assign_child_rollup(socket, socket.assigns.issue.id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:tool_call_trace_created, trace}, socket) do
    if socket.assigns.issue.id == trace.issue_id do
      tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: socket.assigns.issue.id)

      timeline =
        build_timeline(
          socket.assigns.issue,
          socket.assigns.runs,
          socket.assigns.interactions,
          socket.assigns.work_products,
          tool_call_traces
        )

      {:noreply, assign(socket, tool_call_traces: tool_call_traces, timeline: timeline)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:session_started, session_id}, socket) do
    {:noreply, assign(socket, :agent_session_id, session_id)}
  end

  def handle_info({:turn_completed, _session_id, _result}, socket) do
    {:noreply, socket}
  end

  def handle_info({:turn_ended_with_error, _session_id, reason}, socket) do
    {:noreply, put_flash(socket, :error, "Agent error: #{inspect(reason)}")}
  end

  def handle_info({:run_status_changed, payload}, socket) do
    issue_id = socket.assigns.issue.id

    cond do
      payload[:issue_id] == issue_id ->
        {message, type} =
          case payload do
            %{new_status: "running"} -> {"Run started", "info"}
            %{new_status: "completed"} -> {"Run completed successfully", "success"}
            %{new_status: "failed"} -> {"Run failed", "error"}
            %{new_status: "cancelled"} -> {"Run cancelled", "warning"}
            _ -> {"Run status updated", "info"}
          end

        runs = HeartbeatEngine.list_runs_for_issue(issue_id)

        socket =
          socket
          |> assign(:runs, runs)
          |> push_event("toast", %{
            message: message,
            type: type,
            key: "run_#{issue_id}_#{payload[:new_status]}"
          })

        {:noreply, maybe_rebuild_timeline(socket)}

      child_issue_id?(socket, payload[:issue_id]) ->
        {:noreply, assign_child_rollup(socket, issue_id)}

      true ->
        {:noreply, socket}
    end
  end

  def handle_info({:document_updated, updated_document}, socket) do
    if socket.assigns.selected_document &&
         socket.assigns.selected_document.id == updated_document.id do
      revisions = Documents.list_revisions(updated_document.id)
      {:noreply, assign(socket, revisions: revisions)}
    else
      documents = Documents.list_documents(socket.assigns.issue.id)
      {:noreply, assign(socket, documents: documents)}
    end
  end

  defp draft_owner_brief_repair(socket, opts \\ []) do
    flash? = Keyword.get(opts, :flash?, false)

    case IssueBriefReadiness.evaluate(socket.assigns.issue) do
      %{status: status, launch_scaffold: scaffold} when status in [:thin, :draft] ->
        socket = assign(socket, editing: "description", description_draft: scaffold)

        if flash? do
          put_flash(socket, :info, "Repair scaffold loaded into the description editor.")
        else
          socket
        end

      _readiness ->
        socket = assign(socket, editing: "description", description_draft: nil)

        if flash? do
          put_flash(socket, :info, "Owner brief is already ready for CEO launch.")
        else
          socket
        end
    end
  end

  defp assign_child_rollup(socket, issue_id) do
    child_issues = Issues.list_child_issues(issue_id)
    child_tree = Issues.list_descendants_tree(issue_id, 4)
    pending_wake = load_pending_wake_for_issue(socket.assigns[:issue])

    assign(socket,
      child_issues: child_issues,
      child_tree: child_tree,
      pending_wake: pending_wake,
      child_health_cards: child_issue_health_cards(child_issues)
    )
  end

  defp load_pending_wake_for_issue(nil), do: nil

  defp load_pending_wake_for_issue(%{id: id}) do
    Cympho.Wakes.most_recent_pending_for_issues([id]) |> Map.get(id)
  end

  defp refresh_issue_assigns(socket) do
    case get_scoped_issue(socket, socket.assigns.issue.id) do
      {:ok, issue} ->
        socket
        |> assign(:issue, issue)
        |> assign_child_rollup(issue.id)

      {:error, _} ->
        socket
    end
  end

  defp child_issue_id?(socket, issue_id) when is_binary(issue_id) do
    Enum.any?(socket.assigns.child_issues || [], &(&1.id == issue_id))
  end

  defp child_issue_id?(_socket, _issue_id), do: false

  defp get_scoped_issue(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp get_scoped_agent(socket, id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.get_company_agent(company_id, id)
      _ -> {:error, :not_found}
    end
  end

  defp scoped_comment(socket, id) do
    company_id =
      case socket.assigns[:current_company] do
        %{id: id} -> id
        _ -> nil
      end

    route_issue_id = socket.assigns[:route_issue_id] || socket.assigns.issue.id

    with true <- socket.assigns.issue.id == route_issue_id,
         {:ok, comment} <- Comments.get_company_comment(company_id, id),
         true <- comment.issue_id == route_issue_id do
      {:ok, comment}
    else
      _ -> {:error, :not_found}
    end
  end

  defp scoped_interaction(socket, id) do
    with {:ok, interaction} <- IssueThreadInteractions.get_interaction(id),
         true <- interaction.issue_id == socket.assigns.issue.id do
      {:ok, interaction}
    else
      _ -> {:error, :not_found}
    end
  end

  defp list_idle_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_status(:idle, company_id)
      _ -> []
    end
  end

  defp list_company_agents(socket) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Agents.list_agents_by_company(company_id)
      _ -> []
    end
  end

  defp audit_issue_pr_quality(socket, issue) do
    issue = %{issue | project: loaded_project(issue, socket.assigns.issue.project)}

    case Issues.recheck_pr_quality(issue, source: "manual_button") do
      {:ok, updated, pr_quality} ->
        socket
        |> assign(issue: %{updated | project: issue.project})
        |> put_flash(:info, pr_quality_flash(pr_quality))

      {:error, :missing_pr_url} ->
        put_flash(assign(socket, issue: issue), :info, "Set a GitHub PR before checking quality.")

      {:error, _} ->
        put_flash(assign(socket, issue: issue), :error, "Failed to save PR quality result.")
    end
  end

  defp work_product_attrs(socket, params) do
    current_user = socket.assigns[:current_user]

    params
    |> Map.take(["kind", "title", "description", "url"])
    |> Map.update("description", "", &String.trim/1)
    |> Map.update("url", "", &String.trim/1)
    |> Map.update("title", "", &String.trim/1)
    |> Map.put("issue_id", socket.assigns.issue.id)
    |> Map.put("metadata", %{
      "source" => "issue_show",
      "attached_by_user_id" => current_user && current_user.id
    })
  end

  defp apply_comment_template(socket, key) do
    template = Enum.find(comment_templates(), &(&1.key == key))

    changeset =
      case template do
        %{body: body} -> blank_comment_changeset(body)
        _ -> socket.assigns.comment_changeset
      end

    assign(socket, comment_changeset: changeset, comment_form: to_form(changeset))
  end

  defp resolve_review_gate(socket, "delivery_note") do
    socket
    |> apply_comment_template("delivery")
    |> put_flash(:info, "Delivery comment template loaded.")
  end

  defp resolve_review_gate(socket, "review_comment") do
    socket
    |> apply_comment_template("review")
    |> put_flash(:info, "Review comment template loaded.")
  end

  defp resolve_review_gate(socket, "owner_update") do
    socket
    |> apply_comment_template("owner_update")
    |> put_flash(:info, "Owner update template loaded.")
  end

  defp resolve_review_gate(socket, "verification") do
    if socket.assigns.orchestrator_enabled? do
      socket
      |> assign(:show_agent_panel, true)
      |> put_flash(:info, "Agent panel opened for verification.")
    else
      put_flash(socket, :error, "Agent execution is disabled for review mode.")
    end
  end

  defp resolve_review_gate(socket, "work_product") do
    socket
    |> assign(:show_work_product_form, true)
    |> assign(:timeline_filter, "artifacts")
    |> put_flash(:info, "Work product form opened.")
  end

  defp resolve_review_gate(socket, "queue_child_dispatch") do
    queueable_children =
      socket.assigns.child_issues
      |> Enum.map(&Issues.get_issue!(&1.id))
      |> Enum.filter(&child_dispatch_queueable?/1)

    case queueable_children do
      [] ->
        put_flash(socket, :info, "No runnable sub-issues need dispatch.")

      children ->
        results =
          Enum.map(children, fn child ->
            child
            |> assign_owner_for_child_dispatch()
            |> Issues.prioritize_for_dispatch(actor: socket.assigns[:current_user])
          end)

        queued = Enum.count(results, &match?({:ok, _}, &1))
        failed = length(results) - queued

        dispatcher_notified? =
          if queued > 0, do: notify_dispatcher_if_enabled(socket), else: false

        socket =
          socket
          |> assign_child_rollup(socket.assigns.issue.id)
          |> put_child_dispatch_flash(queued, failed, dispatcher_notified?)

        socket
    end
  end

  defp resolve_review_gate(socket, "code_reference") do
    put_flash(socket, :info, "Use the GitHub PR field in the sidebar to set the code reference.")
  end

  defp resolve_review_gate(socket, _action), do: socket

  defp assign_owner_for_child_dispatch(child) do
    case AutoAssignment.assign_owner_for_dispatch(child) do
      {:ok, assigned} -> assigned
      {:error, :no_eligible_agent, issue} -> issue
    end
  end

  defp child_dispatch_queueable?(child) do
    child.status not in [:done, :cancelled] and
      not Issues.dispatch_pinned?(child) and
      not Issues.is_blocked?(child)
  end

  defp put_child_dispatch_flash(socket, queued, 0, true) do
    put_flash(
      socket,
      :info,
      "Queued #{queued} runnable sub-issue#{count_suffix(queued)} and notified the dispatcher."
    )
  end

  defp put_child_dispatch_flash(socket, queued, 0, false) do
    put_flash(
      socket,
      :info,
      "Queued #{queued} runnable sub-issue#{count_suffix(queued)} for focused dispatch. Start runtime from Operations to continue delegated work."
    )
  end

  defp put_child_dispatch_flash(socket, queued, failed, _dispatcher_notified?) do
    put_flash(
      socket,
      :error,
      "Queued #{queued} runnable sub-issue#{count_suffix(queued)}; #{failed} failed to queue."
    )
  end

  defp default_comment_params(socket) do
    case socket.assigns[:current_user] do
      %{id: id} ->
        %{"author_type" => "user", "author_id" => id}

      _ ->
        %{"author_type" => "user", "author_id" => "owner"}
    end
  end

  defp update_status_with_review_gates(socket, status_atom, status) do
    issue = socket.assigns.issue

    cond do
      not Cympho.Issues.StateMachine.valid_transition?(issue.status, status_atom) ->
        {:noreply, put_flash(socket, :error, "Invalid transition")}

      true ->
        case Issues.transition_issue_with_review_gates(issue, status_atom) do
          {:ok, issue} ->
            {:noreply,
             socket
             |> assign(issue: issue)
             |> put_flash(:info, "Status updated to #{status}")}

          {:error, {:review_gates_blocked, %{message: message}}} ->
            {:noreply, put_flash(socket, :error, message)}

          {:error, :blocked_by_active_issues} ->
            {:noreply, put_flash(socket, :error, "Issue is blocked by active issues")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Failed to update status")}
        end
    end
  end

  # Rebuild timeline when issue updates (status changes, etc.)
  defp maybe_rebuild_timeline(socket) do
    interactions = IssueThreadInteractions.list_interactions(socket.assigns.issue.id)
    work_products = WorkProducts.list_work_products(socket.assigns.issue.id)
    tool_call_traces = ToolCallTraces.list_tool_call_traces(issue_id: socket.assigns.issue.id)

    timeline =
      build_timeline(
        socket.assigns.issue,
        socket.assigns.runs,
        interactions,
        work_products,
        tool_call_traces
      )

    socket
    |> assign(:timeline, timeline)
    |> assign(:interactions, interactions)
    |> assign(:work_products, work_products)
    |> assign(:tool_call_traces, tool_call_traces)
  end

  # Check if there's a plan approval blocker for rollback
  defp check_plan_approval_blocker(document_key, issue) do
    if document_key == "plan" do
      # Check if there's an open approval for this issue
      case Cympho.Approvals.list_approvals_for_issue(issue.id) do
        approvals when is_list(approvals) ->
          open_approval = Enum.find(approvals, fn a -> a.status in [:pending, :requested] end)

          if open_approval do
            "Cannot rollback plan document while approval ##{open_approval.id} is open"
          else
            nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp issue_preflight(issue, orchestrator_enabled?) do
    Cympho.RuntimePreflight.for_issue(issue, autonomy_enabled?: orchestrator_enabled?)
  end

  defp delivery_brief_readiness(issue, preflight) do
    if repo_delivery_issue?(issue) or repo_delivery_preflight?(preflight) do
      DeliveryBriefReadiness.evaluate(issue)
    end
  end

  defp repo_delivery_issue?(issue) do
    repo_delivery_role?(Map.get(issue, :assigned_role)) or repo_delivery_assignee?(issue)
  end

  defp repo_delivery_preflight?(%{agent_role: role}), do: repo_delivery_role?(role)
  defp repo_delivery_preflight?(_preflight), do: false

  defp repo_delivery_assignee?(%{assignee: %{role: role}}), do: repo_delivery_role?(role)
  defp repo_delivery_assignee?(_issue), do: false

  defp repo_delivery_role?(role) when is_atom(role),
    do: role |> Atom.to_string() |> repo_delivery_role?()

  defp repo_delivery_role?(role) when is_binary(role), do: role in @repo_delivery_roles
  defp repo_delivery_role?(_role), do: false
end
