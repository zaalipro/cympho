defmodule CymphoWeb.ReviewQueueLive.Index do
  use CymphoWeb, :live_view
  alias Cympho.{HeartbeatEngine, IssueDigest, Issues, Repo, WorkProducts}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) && socket.assigns[:current_company] do
      Issues.subscribe(socket.assigns.current_company.id)
    end

    {:ok,
     socket
     |> assign(:page_title, "Review queue")
     |> load_lanes()}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, load_lanes(socket)}
  end

  @impl true
  def handle_info({:issue_created, _issue}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info({:issue_updated, _issue}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info({:issue_deleted, _id}, socket), do: {:noreply, load_lanes(socket)}
  def handle_info(_other, socket), do: {:noreply, socket}

  @impl true
  def handle_event("approve_review", %{"id" => id}, socket) do
    with {:ok, issue} <- get_scoped_issue(socket, id),
         {:ok, _updated} <- Issues.transition_issue_with_review_gates(issue, :done) do
      {:noreply,
       socket
       |> put_flash(:info, "Review approved and issue closed.")
       |> load_lanes()}
    else
      {:error, {:review_gates_blocked, %{message: message}}} ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, :blocked_by_active_issues} ->
        {:noreply, put_flash(socket, :error, "Resolve active blockers before closing.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not approve this review.")}
    end
  end

  def handle_event("request_changes", %{"id" => id}, socket) do
    with {:ok, issue} <- get_scoped_issue(socket, id),
         {:ok, reopened} <- Issues.transition_issue(issue, :todo),
         {:ok, _updated} <- Issues.update_issue(reopened, request_changes_attrs(issue)) do
      {:noreply,
       socket
       |> put_flash(:info, "Review returned to To Do for changes.")
       |> load_lanes()}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not return this issue for changes.")}
    end
  end

  def handle_event("approve_spec", %{"id" => id}, socket) do
    with {:ok, issue} <- get_scoped_issue(socket, id),
         {:ok, ready} <- Issues.transition_issue(issue, :todo),
         {:ok, _updated} <- Issues.update_issue(ready, %{monitor_state: clear_spec_review(issue)}) do
      {:noreply,
       socket
       |> put_flash(:info, "Spec review approved and queued for execution.")
       |> load_lanes()}
    else
      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Issue not found.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not approve this spec review.")}
    end
  end

  defp load_lanes(socket) do
    case socket.assigns[:current_company] do
      nil ->
        socket
        |> assign(:awaiting_review, [])
        |> assign(:awaiting_review_decisions, [])
        |> assign(:kicked_back, [])
        |> assign(:spec_review, [])
        |> assign(:review_command, empty_review_command())
        |> assign(:stats, empty_stats())

      company ->
        awaiting = list_awaiting_review(company.id)
        awaiting_decisions = Enum.map(awaiting, &decision_card/1)
        kicked_back = list_kicked_back(company.id)
        spec_review = list_spec_review(company.id)

        socket
        |> assign(:awaiting_review, awaiting)
        |> assign(:awaiting_review_decisions, awaiting_decisions)
        |> assign(:kicked_back, kicked_back)
        |> assign(:spec_review, spec_review)
        |> assign(
          :review_command,
          build_review_command(awaiting_decisions, kicked_back, spec_review)
        )
        |> assign(:stats, build_stats(awaiting, kicked_back, spec_review))
    end
  end

  defp get_scoped_issue(socket, issue_id) do
    case socket.assigns[:current_company] do
      %{id: company_id} -> Issues.get_company_issue(company_id, issue_id)
      _ -> {:error, :not_found}
    end
  end

  defp list_awaiting_review(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :in_review)
    |> order_by([i], asc: i.updated_at)
    |> Repo.all()
    |> Repo.preload([:assignee, :project, :last_reviewer, :comments])
  end

  defp list_kicked_back(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :todo and not is_nil(i.last_reviewer_id))
    |> order_by([i], asc: i.updated_at)
    |> Repo.all()
    |> Repo.preload([:assignee, :project, :last_reviewer])
  end

  defp list_spec_review(company_id) do
    import Ecto.Query

    Cympho.Issues.Issue
    |> where([i], i.company_id == ^company_id)
    |> where([i], i.status == :backlog and i.assigned_role == "cto")
    |> where([i], fragment("?->>'spec_review_required' = ?", i.monitor_state, "true"))
    |> order_by([i], asc: i.inserted_at)
    |> Repo.all()
    |> Repo.preload([:project])
  end

  defp empty_stats do
    %{total: 0, oldest_age_hours: nil, by_role: %{}}
  end

  defp build_stats(awaiting, kicked_back, spec_review) do
    all = awaiting ++ kicked_back ++ spec_review

    oldest =
      all
      |> Enum.map(& &1.updated_at)
      |> Enum.min(DateTime, fn -> nil end)

    age_hours =
      case oldest do
        nil ->
          nil

        dt ->
          diff = DateTime.diff(DateTime.utc_now(), dt, :second)
          Float.round(diff / 3600, 1)
      end

    by_role =
      awaiting
      |> Enum.group_by(& &1.assigned_role)
      |> Map.new(fn {role, list} -> {role || "unassigned", length(list)} end)

    %{total: length(all), oldest_age_hours: age_hours, by_role: by_role}
  end

  defp empty_review_command do
    %{
      tone: :clear,
      eyebrow: "Review command",
      heading: "Review queue is clear",
      detail: "No acceptance, rework, or CTO spec decision is waiting right now.",
      action_label: "Open issues",
      action_path: "/issues?triage=review",
      focus: nil,
      blocker_labels: [],
      ready_count: 0,
      blocked_count: 0,
      rework_count: 0,
      spec_count: 0,
      oldest_label: "—"
    }
  end

  defp build_review_command(decision_cards, kicked_back, spec_review) do
    blocked_cards = Enum.filter(decision_cards, &(&1.blocker_count > 0))
    ready_cards = Enum.filter(decision_cards, &(&1.blocker_count == 0))
    oldest = List.first(decision_cards) || first_focus(kicked_back) || first_focus(spec_review)

    command =
      cond do
        blocked_cards != [] ->
          card = List.first(blocked_cards)

          %{
            tone: :attention,
            eyebrow: "Review command",
            heading: "Resolve review gates",
            detail:
              "#{card.label} cannot close yet. Fix the listed evidence gaps before approving it.",
            action_label: "Open gated issue",
            action_path: issue_path(card.issue),
            focus: card,
            blocker_labels: card.blocker_labels
          }

        ready_cards != [] ->
          card = List.first(ready_cards)

          %{
            tone: :ready,
            eyebrow: "Review command",
            heading: "Accept review-ready work",
            detail:
              "#{card.label} has clear approval gates. Inspect the evidence, then approve or request changes.",
            action_label: "Review decision",
            action_path: issue_path(card.issue),
            focus: card,
            blocker_labels: []
          }

        spec_review != [] ->
          issue = List.first(spec_review)

          %{
            tone: :active,
            eyebrow: "Review command",
            heading: "Approve CTO spec gate",
            detail:
              "#{issue_label(issue)} is waiting for CTO initiative acceptance before execution starts.",
            action_label: "Open spec gate",
            action_path: issue_path(issue),
            focus: focus_card(issue, "Spec review", []),
            blocker_labels: []
          }

        kicked_back != [] ->
          issue = List.first(kicked_back)

          %{
            tone: :rework,
            eyebrow: "Review command",
            heading: "Track rework loop",
            detail:
              "#{issue_label(issue)} was returned for changes. Watch the assignee until new evidence lands.",
            action_label: "Open rework issue",
            action_path: issue_path(issue),
            focus: focus_card(issue, "Rework", []),
            blocker_labels: []
          }

        true ->
          empty_review_command()
      end

    command
    |> Map.put(:ready_count, length(ready_cards))
    |> Map.put(:blocked_count, length(blocked_cards))
    |> Map.put(:rework_count, length(kicked_back))
    |> Map.put(:spec_count, length(spec_review))
    |> Map.put(:oldest_label, oldest_label(oldest))
  end

  defp decision_card(issue) do
    runs = HeartbeatEngine.list_runs_for_issue(issue.id)
    work_products = WorkProducts.list_work_products(issue.id)
    child_issues = Issues.list_child_issues(issue.id)

    blockers = IssueDigest.review_status_blockers(issue, :done, runs, work_products, child_issues)

    focus_card(
      issue,
      "Decision",
      blockers,
      review_decision_packet(issue, blockers, runs, work_products, child_issues)
    )
  end

  defp focus_card(issue, lane, blockers, review_packet \\ nil) do
    blocker_labels = Enum.map(blockers, & &1.label)

    %{
      issue: issue,
      lane: lane,
      label: issue_label(issue),
      age: format_age(issue.updated_at),
      role: issue.assigned_role || "unassigned",
      assignee: assignee_name(issue),
      blocker_count: length(blockers),
      blocker_labels: blocker_labels,
      review_packet: review_packet
    }
  end

  defp review_decision_packet(issue, blockers, runs, work_products, child_issues) do
    blocker_count = length(blockers)
    completed_runs = Enum.count(runs, &(&1.status in ["completed", "succeeded"]))
    failed_runs = Enum.count(runs, &(&1.status in ["failed", "timed_out"]))
    closed_children = Enum.count(child_issues, &(&1.status in [:done, :cancelled]))
    total_children = length(child_issues)

    %{
      tone: if(blocker_count == 0, do: :ready, else: :attention),
      verdict:
        if(blocker_count == 0,
          do: "Approve candidate",
          else: "Request changes first"
        ),
      summary:
        if(blocker_count == 0,
          do: "Review gates are clear; perform final human inspection before closing.",
          else:
            "#{blocker_count} review #{if blocker_count == 1, do: "gate", else: "gates"} still block approval."
        ),
      evidence: [
        run_evidence_line(completed_runs, failed_runs),
        work_product_evidence_line(work_products),
        pr_evidence_line(issue),
        child_issue_evidence_line(closed_children, total_children)
      ],
      risks: review_risk_lines(blockers)
    }
  end

  defp run_evidence_line(completed_runs, failed_runs) do
    cond do
      completed_runs > 0 and failed_runs > 0 ->
        "#{completed_runs} completed runtime #{plural_suffix(completed_runs)}; #{failed_runs} failed #{plural_suffix(failed_runs)} need review."

      completed_runs > 0 ->
        "#{completed_runs} completed runtime #{plural_suffix(completed_runs)} recorded."

      failed_runs > 0 ->
        "#{failed_runs} failed runtime #{plural_suffix(failed_runs)} recorded; inspect before approval."

      true ->
        "No completed runtime run recorded."
    end
  end

  defp work_product_evidence_line([]), do: "No work product attached."

  defp work_product_evidence_line(work_products) do
    code_count = Enum.count(work_products, &(&1.kind == "code_change"))

    "#{length(work_products)} work #{plural_noun(length(work_products), "product")} attached#{if code_count > 0, do: " (#{code_count} code)", else: ""}."
  end

  defp pr_evidence_line(issue) do
    if Cympho.Issues.Issue.pr_url(issue, issue.project) in [nil, ""] do
      "No PR link set."
    else
      "PR link is set."
    end
  end

  defp child_issue_evidence_line(_closed_children, 0), do: "No delegated sub-issues."

  defp child_issue_evidence_line(closed_children, total_children) do
    "#{closed_children}/#{total_children} delegated #{plural_noun(total_children, "sub-issue")} closed."
  end

  defp review_risk_lines([]) do
    ["No blocking review gate detected. Confirm product quality manually before approval."]
  end

  defp review_risk_lines(blockers) do
    blockers
    |> Enum.map(& &1.label)
    |> Enum.take(4)
  end

  defp plural_suffix(1), do: "run"
  defp plural_suffix(_), do: "runs"

  defp plural_noun(1, noun), do: noun
  defp plural_noun(_count, noun), do: noun <> "s"

  defp review_gate_heading(%{blocker_count: 0}), do: "Ready for close"
  defp review_gate_heading(_card), do: "Evidence gaps block closure"

  defp review_gate_detail(%{blocker_count: 0}) do
    "Approval gates are clear. Inspect the issue evidence, then approve or request changes."
  end

  defp review_gate_detail(%{blocker_count: 1}) do
    "Fix this gate before approving. The close action will stay guarded until evidence is present."
  end

  defp review_gate_detail(%{blocker_count: count}) do
    "Fix these #{count} gates before approving. The close action will stay guarded until evidence is present."
  end

  # Emerald and red are reserved for the approve / return actions themselves.
  # Gate telemetry uses amber only when something blocks; clear gates read calm.
  defp review_gate_card_class(%{blocker_count: 0}) do
    "border-border bg-surface/60"
  end

  defp review_gate_card_class(_card), do: "border-amber-500/25 bg-amber-500/[0.06]"

  defp review_gate_badge_class(%{blocker_count: 0}) do
    "border-border bg-surface text-text-tertiary"
  end

  defp review_gate_badge_class(_card), do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp review_packet_card_class(%{tone: :ready}) do
    "border-border bg-surface/60"
  end

  defp review_packet_card_class(_packet), do: "border-amber-500/20 bg-amber-500/[0.04]"

  defp review_packet_badge_class(%{tone: :ready}) do
    "border-border bg-surface text-text-secondary"
  end

  defp review_packet_badge_class(_packet),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp assignee_name(%{assignee: %Ecto.Association.NotLoaded{}}), do: nil
  defp assignee_name(%{assignee: %{name: name}}), do: name
  defp assignee_name(_), do: nil

  defp first_focus([]), do: nil
  defp first_focus([issue | _]), do: focus_card(issue, lane_label(issue), [])

  defp issue_label(issue), do: "#{issue.identifier || "Issue"} · #{issue.title}"
  defp issue_path(issue), do: "/issues/#{issue.id}"

  defp lane_label(%{status: :todo}), do: "Rework"
  defp lane_label(%{status: :backlog}), do: "Spec review"
  defp lane_label(_issue), do: "Review"

  defp oldest_label(nil), do: "—"
  defp oldest_label(%{age: age}) when is_binary(age), do: age
  defp oldest_label(%{issue: issue}), do: format_age(issue.updated_at)

  defp review_command_tone_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200"

  defp review_command_tone_class(tone) when tone in [:ready, :active],
    do: "border-brand/25 bg-brand/10 text-brand"

  defp review_command_tone_class(_),
    do: "border-border bg-surface text-text-secondary"

  defp review_command_action_class(:attention),
    do: "border-amber-500/25 bg-amber-500/10 text-amber-200 hover:bg-amber-500/15"

  defp review_command_action_class(tone) when tone in [:ready, :active],
    do: "border-brand/25 bg-brand/10 text-brand hover:bg-brand/15"

  defp review_command_action_class(_),
    do:
      "border-border bg-surface text-text-secondary hover:bg-surface-hover hover:text-text-primary"

  defp request_changes_attrs(issue) do
    %{
      assignee_id: nil,
      assigned_role: return_role(issue.assigned_role),
      checkout_run_id: nil,
      checked_out_at: nil,
      last_reviewer_id: issue.assignee_id || issue.last_reviewer_id
    }
  end

  defp return_role("ceo"), do: "cto"
  defp return_role("cto"), do: "engineer"
  defp return_role(role) when is_binary(role) and role != "", do: role
  defp return_role(_), do: "engineer"

  defp clear_spec_review(issue) do
    issue.monitor_state
    |> normalize_monitor_state()
    |> Map.delete("spec_review_required")
    |> Map.delete(:spec_review_required)
  end

  defp normalize_monitor_state(%{} = monitor_state), do: monitor_state
  defp normalize_monitor_state(_), do: %{}

  def status_color(:backlog), do: "bg-gray-400"
  def status_color(:todo), do: "bg-blue-400"
  def status_color(:in_progress), do: "bg-yellow-400"
  def status_color(:in_review), do: "bg-purple-400"
  def status_color(:done), do: "bg-green-400"
  def status_color(:blocked), do: "bg-brand"
  def status_color(_), do: "bg-gray-400"

  def format_age(updated_at) do
    diff_sec = DateTime.diff(DateTime.utc_now(), updated_at, :second)

    cond do
      diff_sec < 60 -> "just now"
      diff_sec < 3_600 -> "#{div(diff_sec, 60)}m"
      diff_sec < 86_400 -> "#{div(diff_sec, 3_600)}h"
      true -> "#{div(diff_sec, 86_400)}d"
    end
  end
end
