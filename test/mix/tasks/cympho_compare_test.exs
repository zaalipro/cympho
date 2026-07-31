defmodule Mix.Tasks.CymphoCompareTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  test "json mode emits decodable JSON without routine app logs" do
    previous_level = Logger.level()
    previous_repo_config = Application.get_env(:cympho, Cympho.Repo)
    parent = self()

    log =
      capture_log(fn ->
        output =
          capture_io(fn ->
            Mix.Task.reenable("app.start")
            Mix.Tasks.Cympho.Compare.run(["--json"])
          end)

        send(parent, {:compare_output, output})
      end)

    assert_receive {:compare_output, output}

    assert log == ""
    assert Logger.level() == previous_level
    assert Application.get_env(:cympho, Cympho.Repo) == previous_repo_config
    assert output |> String.trim_leading() |> String.starts_with?("[")

    rows = Jason.decode!(output)

    assert %{"verdict" => "parity", "evidence" => adapter_evidence} =
             Enum.find(rows, &(&1["slug"] == "bring_your_own_agent"))

    assert adapter_evidence =~ "broader adapter package catalog"

    assert Enum.all?(rows, fn row ->
             row["paperclip_revision"] == "c62fa8d6a03377370c3a08ac49320cbba1c44227" and
               row["paperclip_inspected_on"] == "2026-07-30"
           end)

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "cost_control"))

    assert evidence =~ "runtime enforcement is scored separately"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "runtime_budget_enforcement"))

    assert evidence =~ "OpenAI-compatible usage"
    assert evidence =~ "tenant-validated, idempotent ledger"
    assert evidence =~ "company/agent/issue/project/goal"
    assert evidence =~ "active"
    assert evidence =~ "process crash"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "adapter_circuit_breaker"))

    assert evidence =~ "adapter circuit breaker"
    assert evidence =~ "3 consecutive adapter-resolution failures"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "no_progress_circuit_breaker"))

    assert evidence =~ "No-progress circuit breaker"
    assert evidence =~ "3 consecutive unresolved action-contract failures"
    assert evidence =~ "cancels queued wakes"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "ticket_system"))

    assert evidence =~ "issue-memory handoff packets"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "server_inbox_badge_counts"))

    assert evidence =~ "unread_count_for_company"
    assert evidence =~ "company PubSub updates"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "human_action_inbox"))

    assert evidence =~ "Needs my action"
    assert evidence =~ "current human user"
    assert evidence =~ "notification-only noise"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "owner_decisions_queue"))

    assert evidence =~ "company-scoped Inbox queue"
    assert evidence =~ "reviews"
    assert evidence =~ "approvals"
    assert evidence =~ "failed runs"
    assert evidence =~ "budget incidents"
    assert evidence =~ "pending questions/confirmations/task proposals"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "scoped_agent_task_assignment"))

    assert evidence =~ "auditable grant path"
    assert evidence =~ "task.assign/task.create"
    assert evidence =~ "can_assign_tasks"
    assert evidence =~ "without CEO involvement"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "governance"))

    assert evidence =~ "governance risk briefs"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "org_chart"))

    assert evidence =~ "org health diagnostics"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "tool_call_tracing"))

    assert evidence =~ "SHA-256 content hashes"
    assert evidence =~ "content+chain verification"
    assert evidence =~ "stale or tampered traces"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "routines_schedules"))

    assert evidence =~ "health diagnostics"
    assert evidence =~ "stale runs"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "workspaces"))

    assert evidence =~ "execution health"
    assert evidence =~ "preview gaps"
    assert evidence =~ "remote sandbox execution is scored separately"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "plugins"))

    assert evidence =~ "owner-visible health"
    assert evidence =~ "capability gaps"
    assert evidence =~ "dynamic extension registration is scored separately"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "local_plugin_catalog_integrity"))

    assert evidence =~ "source-backed"
    assert evidence =~ "start_link/1"
    assert evidence =~ "fabricated ratings/download counts are absent"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "external_otlp_tracing"))

    assert evidence =~ "fail-open OTLP export"
    assert evidence =~ "allowlisted correlation spans"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "goal_alignment"))

    assert evidence =~ "alignment coverage"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "zero_token_idle_heartbeats"))

    assert evidence =~ "keeps no-work timer heartbeats idle"
    assert evidence =~ "only marks running after a todo issue is checked out"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "stale_lock_recovery"))

    assert evidence =~ "preserves assignee ownership"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "run_checkout_ownership"))

    assert evidence =~ "bind checkout_run_id before dispatch"
    assert evidence =~ "aborts provider invocation"
    assert evidence =~ "without releasing a successor"
    assert evidence =~ "compare-clears by run id"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "stale_patrol_exclusion"))

    assert evidence =~ "monitor_state[\"patrol\"]"
    assert evidence =~ "Issues.list_stuck_issues/2"
    assert evidence =~ "without changing workflow status"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "closed_issue_runtime_cleanup"))

    assert evidence =~ "Terminal issue cleanup"
    assert evidence =~ "pending/running issue wakes"
    assert evidence =~ "pending/queued/running run rows"
    assert evidence =~ "closed work from restarting"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "blocked_issue_routing_guard"))

    assert evidence =~ "Blocked issue routing guard"
    assert evidence =~ "parked blocked work"
    assert evidence =~ "automatic dispatcher selection"
    assert evidence =~ "cancelled blockers"
    assert evidence =~ "dependent issues reopen"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "global_runtime_controls"))

    assert evidence =~ "Pause/Resume/Stop"
    assert evidence =~ "AdapterSessions"
    assert evidence =~ "requested/confirmed/still-registered adapter cancellation counts"
    assert evidence =~ "preserved"
    assert evidence =~ "runtime audit events"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "issue_runtime_pause"))

    assert evidence =~ "Issue-level Pause/Resume"
    assert evidence =~ "blocks checkout"
    assert evidence =~ "dispatcher selection"
    assert evidence =~ "issue-scoped runtime audit events"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "low_power_runtime_mode"))

    assert evidence =~ "keeps the company active"
    assert evidence =~ "runtime_mode=low_power"
    assert evidence =~ "high/critical priority work"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "keyboard_first_view_modes"))

    assert evidence =~ "accessible Compact/Detailed state"
    assert evidence =~ "V toggles"
    assert evidence =~ "U toggles"
    assert evidence =~ "shortcuts modal"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "comment_mention_delivery"))

    assert evidence =~ "exact assignee/agent mentions"
    assert evidence =~ "suppress assigned-agent self-comments"
    assert evidence =~ "blocked/done/cancelled"
    assert evidence =~ "comment author metadata"
    assert evidence =~ "prompt preamble"
    assert evidence =~ "triggering comment body"
    assert evidence =~ "fresh turns"
    assert evidence =~ "stale CLI sessions"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "current_task_prompt_contract"))

    assert evidence =~ "current-task block"
    assert evidence =~ "company operating context"
    assert evidence =~ "instruction files"
    assert evidence =~ "triggering comment body"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "attachment_context_visibility"))

    assert evidence =~ "inline small text content"
    assert evidence =~ "base64 data URIs"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "runtime_timeout_policy"))

    assert evidence =~ "timeout_sec"
    assert evidence =~ "no timeoutSec: 0"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "runtime_workspace_env_contract"))

    assert evidence =~ "single workspace/env contract"
    assert evidence =~ "CYMPHO_RUN_ID"
    assert evidence =~ "Cursor consumes runtime env/cwd"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "workspace_isolation_preflight"))

    assert evidence =~ "Local repo-delivery preflight"
    assert evidence =~ "shared project workspace"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "bounded_run_observability"))

    assert evidence =~ "Bounded run history"
    assert evidence =~ "server-side total run counts"
    assert evidence =~ "latest-N-of-total ledger feedback"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "wake_queue_context_integrity"))

    assert evidence =~ "Wake queue context integrity"
    assert evidence =~ "duplicate pending wakes bounded"
    assert evidence =~ "coalesced comment/review ids"
    assert evidence =~ "triggering comment body"
    assert evidence =~ "stale queue snapshot"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "review_recovery_dedup"))

    assert evidence =~ "one active issue/agent/nudge chain"
    assert evidence =~ "superseded rows are consumed"
    assert evidence =~ "re_emit_of/re_emit_count"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "activity_incremental_cursor"))

    assert evidence =~ "Activity incremental cursor"
    assert evidence =~ "ISO8601 since"
    assert evidence =~ "clamps pagination"
    assert evidence =~ "rejects invalid cursors"
    assert evidence =~ "replay full history"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "outbound_webhook_notifications"))

    assert evidence =~ "Outbound webhook notifications"
    assert evidence =~ "HMAC signatures"
    assert evidence =~ "event_type payloads"
    assert evidence =~ "not forced to poll"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "clipboard_copy_resilience"))

    assert evidence =~ "Clipboard API"
    assert evidence =~ "self-hosted HTTP"
    assert evidence =~ "failure feedback"
    assert evidence =~ "button/icon markup"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "process_output_utf8_integrity"))

    assert evidence =~ "Process output UTF-8 integrity"
    assert evidence =~ "valid multilingual CLI output"
    assert evidence =~ "malformed subprocess bytes"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "company_portability"))

    assert evidence =~ "non-secret secret manifest"
    assert evidence =~ "restore checklist"
    assert evidence =~ "tracked separately"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "company_import_preview"))

    assert evidence =~ "read-only"
    assert evidence =~ "planned writes"
    assert evidence =~ "strict reference validation"
    assert evidence =~ "non-secret restore requirements"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "company_blueprints"))

    assert evidence =~ "17 executable"
    assert evidence =~ "Paperclip's public catalog is still larger"
    assert evidence =~ "launch manifests"
    assert evidence =~ "default agents"
    assert evidence =~ "unique capability tags"
    assert evidence =~ "created companies store the manifest"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "mcp_server"))

    assert evidence =~ "external AI clients"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "revision_pinned_plan_approval"))

    assert evidence =~ "reject acceptance"
    assert evidence =~ "target revision is stale"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "task_work_modes"))

    assert evidence =~ "standard/planning/ask intent"
    assert evidence =~ "Claude and Codex"
    assert evidence =~ "read-only"
    assert evidence =~ "External HTTP/process adapters"

    assert %{"verdict" => "parity", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "resumable_onboarding"))

    assert evidence =~ "allowlisted non-secret user draft"
    assert evidence =~ "atomically clears"
    assert evidence =~ "stale replay"
    assert evidence =~ "duplicate work"

    assert %{"verdict" => "parity", "evidence" => review_nudge_evidence} =
             Enum.find(rows, &(&1["slug"] == "review_nudges"))

    assert review_nudge_evidence =~ "does not infer superiority"

    assert %{"verdict" => "parity", "evidence" => rate_limit_evidence} =
             Enum.find(rows, &(&1["slug"] == "rate_limiting"))

    assert rate_limit_evidence =~ "different extension-call boundary"

    expected_open_gaps = [
      "remote_sandbox_execution",
      "governed_dynamic_mcp",
      "durable_eval_feedback",
      "selective_standard_portability"
    ]

    for slug <- expected_open_gaps do
      assert %{"verdict" => "gap", "evidence" => evidence} =
               Enum.find(rows, &(&1["slug"] == slug))

      assert is_binary(evidence) and evidence != ""
    end

    assert Enum.find(rows, &(&1["slug"] == "remote_sandbox_execution"))["evidence"] =~
             "real remote provider"

    assert Enum.find(rows, &(&1["slug"] == "governed_dynamic_mcp"))["evidence"] =~
             "local plugin lifecycle"

    assert Enum.find(rows, &(&1["slug"] == "durable_eval_feedback"))["evidence"] =~
             "saved evaluation runs"

    assert %{"verdict" => "parity", "evidence" => mobile_evidence} =
             Enum.find(rows, &(&1["slug"] == "mobile_safe_area_evidence"))

    assert mobile_evidence =~ "safe-area and dynamic-viewport"
    assert mobile_evidence =~ "keyboard-open"
    assert mobile_evidence =~ "landscape evidence"

    assert Enum.find(rows, &(&1["slug"] == "selective_standard_portability"))["evidence"] =~
             "local/GitHub/ref"

    assert %{"verdict" => "exceeds", "evidence" => evidence} =
             Enum.find(rows, &(&1["slug"] == "secrets"))

    assert evidence =~ "rotation posture"
    refute output =~ "[debug]"
  end
end
