defmodule Cympho.Recovery do
  @moduledoc "Durable case and lease lifecycle for stranded work recovery."
  import Ecto.Query
  require Logger
  alias Cympho.Repo
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.HeartbeatEngine.Run
  alias Cympho.HeartbeatEngine
  alias Cympho.Workspaces
  alias Cympho.Orchestrator
  alias Cympho.RuntimeOperations
  alias Cympho.Recovery.{Fingerprint, RecoveryAttempt, RecoveryCase}
  alias Cympho.BoardApprovals
  alias Cympho.BoardApprovals.BoardApproval
  alias Cympho.GovernanceAuditLogs

  @lease_seconds 300
  @terminal_run_statuses ~w(completed succeeded failed cancelled timed_out done)

  @doc "Escalates an exhausted recovery case to a single board retry proposal."
  def exhaust_case(%RecoveryCase{id: id} = case_row, opts \\ []) do
    reason = Keyword.get(opts, :reason) || case_row.last_error
    now = option_now(opts)

    result =
      Repo.transaction(fn ->
        locked =
          case Repo.one(from c in RecoveryCase, where: c.id == ^id, lock: "FOR UPDATE") do
            %RecoveryCase{} = row -> row
            nil -> Repo.rollback(:not_found)
          end

        issue =
          case Repo.one(from i in Issue, where: i.id == ^locked.issue_id, lock: "FOR UPDATE") do
            %Issue{} = row -> row
            nil -> Repo.rollback(:not_found)
          end

        existing_approval =
          Repo.one(
            from a in BoardApproval,
              where: a.recovery_case_id == ^locked.id,
              lock: "FOR UPDATE"
          )

        cond do
          not approval_scope_matches?(existing_approval, locked) ->
            Repo.rollback(:invalid_recovery_approval)

          locked.state in ["recovered", "resolved", "superseded"] ->
            {:historical, locked}

          locked.state not in ["exhausted", "escalated"] ->
            Repo.rollback(:case_not_exhausted)

          # Blocking the issue updates the checkout fingerprint. Once an
          # approval has been persisted, a repeated exhaustion callback must
          # return that durable proposal rather than treating its own block as
          # a stale source and superseding the case.
          locked.company_id == issue.company_id and match?(%BoardApproval{}, existing_approval) and
              idempotent_escalation?(locked, issue) ->
            {:existing, Repo.preload(existing_approval, [:company, :recovery_case])}

          true ->
            {:new, do_exhaust_case(locked, issue, existing_approval, reason, now)}
        end
      end)

    case result do
      {:ok, {:existing, %BoardApproval{} = approval}} ->
        {:ok, approval}

      {:ok, {:new, %BoardApproval{} = approval}} ->
        Cympho.PubSubGuard.company_broadcast(
          approval.company_id,
          "approvals",
          {:board_approval_created, approval}
        )

        Cympho.PubSubGuard.broadcast(
          "system:board_approvals",
          {:board_approval_created, approval}
        )

        _ = Cympho.OwnerAttention.notify_changed(approval.company_id)

        GovernanceAuditLogs.log_action(
          "recovery_exhausted",
          {"system", approval.company_id},
          "Recovery case exhausted",
          resource: approval
        )

        {:ok, approval}

      {:ok, {:new, %RecoveryCase{} = superseded}} ->
        resolve_superseded_approval(superseded.id)
        {:ok, superseded}

      {:ok, {:historical, %RecoveryCase{} = historical}} ->
        {:ok, historical}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_exhaust_case(locked, issue, existing_approval, reason, now) do
    if locked.company_id == issue.company_id and
         approval_scope_matches?(existing_approval, locked) and
         source_matches?(locked, issue) and
         issue.status not in [:done, :cancelled, "done", "cancelled"] do
      if issue.status not in [:blocked, "blocked"] do
        Repo.update_all(from(i in Issue, where: i.id == ^issue.id),
          set: [status: :blocked, updated_at: now],
          inc: [lock_version: 1]
        )
      end

      approval =
        case existing_approval do
          nil ->
            packet = %{
              "issue_id" => issue.id,
              "case_id" => locked.id,
              "source_type" => locked.source_type,
              "attempts" => bounded_attempt_history(locked.id)
            }

            attrs = %{
              title: "Retry stranded work: #{issue.title}",
              description:
                "Work is paused after automatic recoveries. Approve Retry to run it once more; deny to leave it paused for reassignment or cancellation.",
              company_id: locked.company_id,
              recovery_case_id: locked.id,
              proposal_data: %{
                "action" => "retry",
                "case_id" => locked.id,
                "issue_id" => issue.id,
                "source_type" => locked.source_type,
                "source_run_id" => locked.source_run_id,
                "fingerprint" => locked.source_fingerprint,
                "attempt_count" => locked.attempt_count,
                "max_attempts" => locked.max_attempts,
                "last_error" => bounded_error(reason),
                "attempt_history" => bounded_attempt_history(locked.id),
                "restart_packet" => packet
              },
              # `now` may be supplied by deterministic recovery scans and
              # can legitimately predate wall-clock time. Board approval
              # validation requires a deadline in the future, so derive
              # this human-review deadline from the current clock rather
              # than allowing a historical scan timestamp to invalidate
              # the escalation transaction.
              review_deadline: review_deadline(now)
            }

            case BoardApprovals.create_recovery_approval(attrs) do
              {:ok, row} -> row
              {:error, error} -> Repo.rollback({:recovery_approval_failed, error})
            end

          row ->
            row
        end

      Repo.update_all(from(c in RecoveryCase, where: c.id == ^locked.id),
        set: [
          state: "escalated",
          exhausted_at: locked.exhausted_at || now,
          escalated_at: now,
          claim_token: nil,
          claimed_at: nil,
          lease_expires_at: nil,
          claimed_by: nil
        ]
      )

      Repo.preload(approval, [:company, :recovery_case])
    else
      Repo.update_all(from(c in RecoveryCase, where: c.id == ^locked.id),
        set: [
          state: "superseded",
          resolved_at: now,
          claim_token: nil,
          claimed_at: nil,
          lease_expires_at: nil,
          claimed_by: nil,
          next_attempt_at: nil
        ]
      )

      if match?(%BoardApproval{status: "pending"}, existing_approval) do
        existing_approval
        |> Ecto.Changeset.change(%{
          status: "cancelled",
          decision_reasoning: "Recovery source superseded"
        })
        |> Repo.update!()
      end

      Repo.get!(RecoveryCase, locked.id)
    end
  end

  defp resolve_superseded_approval(case_id) when is_binary(case_id) do
    case Repo.get_by(BoardApproval, recovery_case_id: case_id, status: "cancelled") do
      %BoardApproval{} = approval ->
        _ = Cympho.Recovery.handle_approval_resolution(approval)

        Cympho.PubSubGuard.company_broadcast(
          approval.company_id,
          "approvals",
          {:board_approval_cancelled, approval}
        )

        Cympho.PubSubGuard.broadcast(
          "system:board_approvals",
          {:board_approval_cancelled, approval}
        )

        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp publish_superseded_approval(case_id) when is_binary(case_id) do
    resolve_superseded_approval(case_id)
  end

  defp publish_superseded_approval(_), do: :ok

  defp idempotent_escalation?(
         %RecoveryCase{state: state, source_status: source_status, source_snapshot: snapshot},
         %Issue{status: status, lock_version: lock_version}
       )
       when state in ["escalated", "exhausted"] and status in [:blocked, "blocked"] do
    # A first escalation changes a non-terminal issue to blocked and bumps its
    # optimistic-lock version. Accept that exact durable transition on a
    # repeated callback, but do not let a later terminal/owner mutation reuse
    # an old approval as though it were still the same source.
    source_lock = snapshot_lock_version(snapshot)

    cond do
      source_status in [:blocked, "blocked"] -> source_lock == lock_version
      is_integer(source_lock) -> source_lock + 1 == lock_version
      true -> false
    end
  end

  defp idempotent_escalation?(_, _), do: false

  defp approval_scope_matches?(nil, _case_row), do: true

  defp approval_scope_matches?(
         %BoardApproval{
           category: "stranded_work_recovery",
           status: "pending",
           recovery_case_id: approval_case_id,
           company_id: company_id
         },
         %RecoveryCase{id: case_id, company_id: case_company_id}
       ),
       do: approval_case_id == case_id and company_id == case_company_id

  defp approval_scope_matches?(_, _), do: false

  defp snapshot_lock_version(snapshot) when is_map(snapshot) do
    snapshot["lock_version"] || snapshot["issue_lock_version"]
  end

  defp snapshot_lock_version(_), do: nil

  @doc "Resolves a recovery case when its board approval is denied or cancelled."
  def handle_approval_resolution(%BoardApproval{
        id: approval_id
      })
      when is_binary(approval_id) do
    result =
      Repo.transaction(fn ->
        with %BoardApproval{
               category: "stranded_work_recovery",
               status: status,
               recovery_case_id: id,
               company_id: company_id
             } = persisted
             when status in ["denied", "expired", "cancelled"] and is_binary(id) and
                    is_binary(company_id) <-
               Repo.one(
                 from a in BoardApproval,
                   where: a.id == ^approval_id,
                   lock: "FOR UPDATE"
               ),
             %RecoveryCase{} = c <-
               Repo.one(
                 from c in RecoveryCase,
                   where: c.id == ^id and c.company_id == ^company_id,
                   lock: "FOR UPDATE"
               ) do
          case c.state do
            state when state in ["detected", "scheduled", "claimed", "exhausted", "escalated"] ->
              now = DateTime.utc_now() |> DateTime.truncate(:second)

              # If a lease was still held when an operator denied/expired the
              # proposal, clear it as part of resolution so no worker can
              # complete a stale attempt after the human decision.
              Repo.update_all(from(c2 in RecoveryCase, where: c2.id == ^c.id),
                set: [
                  state: "resolved",
                  resolved_at: now,
                  claim_token: nil,
                  claimed_at: nil,
                  lease_expires_at: nil,
                  claimed_by: nil,
                  next_attempt_at: nil
                ]
              )

              {:changed, persisted, c, status, company_id}

            _terminal_or_historical ->
              :unchanged
          end
        else
          _ -> :unchanged
        end
      end)

    case result do
      {:ok, {:changed, approval, case_row, status, company_id}} ->
        # All governance effects are emitted only after the resolution
        # transaction commits.  This also makes startup reconciliation safe.
        GovernanceAuditLogs.log_action(
          "recovery_resolved",
          {"system", company_id},
          "Stranded-work recovery approval #{status}",
          resource: approval,
          metadata: %{recovery_case_id: case_row.id, resolution: status}
        )

        Cympho.PubSubGuard.company_broadcast(
          company_id,
          "approvals",
          {:recovery_case_resolved, approval, case_row}
        )

        _ = Cympho.OwnerAttention.notify_changed(company_id)
        :ok

      {:ok, :unchanged} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_approval_resolution(_), do: :ok

  @doc "Applies an approved stranded-work recovery retry exactly once."
  def apply_board_action(approval, opts \\ [])

  def apply_board_action(%BoardApproval{id: approval_id} = _caller, opts)
      when is_binary(approval_id) do
    defer_side_effects? = Keyword.get(opts, :defer_side_effects, false)
    now = option_now(opts)

    result =
      Repo.transaction(fn ->
        # The caller struct is only an address.  Never trust status/category,
        # company, linkage, or proposal fields from an unsaved/forged struct;
        # the locked database row is the authority.
        persisted =
          Repo.one(
            from a in BoardApproval,
              where: a.id == ^approval_id,
              lock: "FOR UPDATE"
          )

        with %BoardApproval{} = persisted <- persisted,
             :ok <- valid_persisted_retry_approval(persisted, now),
             {:ok, case_id, data} <- persisted_retry_payload(persisted),
             %RecoveryCase{} = case_row <-
               Repo.one(from c in RecoveryCase, where: c.id == ^case_id, lock: "FOR UPDATE"),
             :ok <- valid_case_linkage(persisted, case_row, data),
             %Issue{} = issue <-
               Repo.one(from i in Issue, where: i.id == ^case_row.issue_id, lock: "FOR UPDATE"),
             :ok <- valid_retry_issue(case_row, issue, data) do
          # Clear any failed checkout binding and the runtime pause using the
          # exact source snapshot before changing the visible status.  The
          # update is one CAS on lock_version/binding, so a successor wins.
          issue_after =
            case resume_retry_issue(case_row, issue, now) do
              {:ok, updated} -> updated
              {:error, _reason} -> Repo.rollback(:stale_recovery_proposal)
            end

          Repo.update_all(
            from(c in RecoveryCase, where: c.id == ^case_row.id and c.state == "escalated"),
            set: [state: "resolved", resolved_at: now, next_attempt_at: nil]
          )

          {child_fp, child_snapshot} =
            case retry_child_fingerprint(case_row, issue_after) do
              {:ok, value} -> value
              {:error, reason} -> Repo.rollback(reason)
            end

          source_id =
            case canonical_source_id(case_row, issue_after) do
              id when is_binary(id) and id != "" -> id
              _ -> Repo.rollback(:stale_recovery_proposal)
            end

          child_attrs = %{
            company_id: issue_after.company_id,
            issue_id: issue_after.id,
            agent_id: case_row.agent_id || issue_after.assignee_id,
            source_run_id: case_row.source_run_id,
            parent_case_id: case_row.id,
            root_case_id: case_row.root_case_id || case_row.id,
            source_type: case_row.source_type,
            # Retry children use the canonical scanner key.  Historical rows
            # may share this identity, but the active partial index prevents a
            # second root/child from coexisting.
            source_id: source_id,
            source_status: to_string(issue_after.status),
            source_fingerprint: child_fp,
            fingerprint_version: Fingerprint.version(),
            source_snapshot: child_snapshot,
            policy_snapshot:
              case_row.policy_snapshot || policy_snapshot(case_row.max_attempts, []),
            max_attempts: case_row.max_attempts,
            state: "scheduled",
            next_attempt_at: now
          }

          child = insert_retry_child!(child_attrs)
          {:applied, persisted, child, issue, issue_after}
        else
          _ -> Repo.rollback(:stale_recovery_proposal)
        end
      end)

    case result do
      {:ok, {:applied, persisted, child, issue_before, issue_after}} ->
        unless defer_side_effects? do
          publish_retry_applied(persisted, child, issue_before, issue_after)
        end

        {:ok, child}

      {:error, :stale_recovery_proposal} ->
        audit_stale_retry_proposal(approval_id)
        {:error, :stale_recovery_proposal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def apply_board_action(_, _opts), do: {:error, :stale_recovery_proposal}

  defp audit_stale_retry_proposal(approval_id) do
    case Repo.get(BoardApproval, approval_id) do
      %BoardApproval{company_id: company_id} = approval when is_binary(company_id) ->
        _ =
          GovernanceAuditLogs.log_action(
            "recovery_retry_stale",
            {"system", company_id},
            "Approved stranded-work retry was stale and not applied",
            resource: approval,
            metadata: %{board_approval_id: approval_id}
          )

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc false
  def publish_retry_applied(
        %BoardApproval{} = approval,
        %RecoveryCase{} = child,
        _before,
        after_issue
      ) do
    company_id = approval.company_id

    GovernanceAuditLogs.log_action(
      "recovery_retry_approved",
      {"system", company_id},
      "Approved retry queued for stranded work",
      resource: approval,
      metadata: %{recovery_case_id: child.id, parent_case_id: child.parent_case_id}
    )

    Cympho.PubSubGuard.company_broadcast(
      company_id,
      "approvals",
      {:recovery_retry_approved, approval, child}
    )

    # The issue mutation is intentionally silent while the effect transaction
    # is open. Emit the normal issue/activity signals only after that outer
    # transaction has committed (or reload the committed child issue when the
    # executor did not carry it through the callback result).
    issue =
      case after_issue do
        %Issue{} = value -> value
        _ -> Repo.get(Issue, child.issue_id)
      end

    if %Issue{company_id: ^company_id} = issue do
      _ =
        Cympho.Activities.log_activity(%{
          issue_id: issue.id,
          company_id: company_id,
          actor_type: "system",
          action: "recovery_retry_queued",
          metadata: %{recovery_case_id: child.id, parent_case_id: child.parent_case_id}
        })

      Cympho.PubSubGuard.company_broadcast(company_id, "issues", {:issue_updated, issue})
    end

    _ = Cympho.OwnerAttention.notify_changed(company_id)
    _ = Cympho.Orchestrator.Dispatcher.poll_company(company_id)
    :ok
  end

  defp valid_persisted_retry_approval(
         %BoardApproval{
           status: "approved",
           category: "stranded_work_recovery",
           recovery_case_id: id,
           company_id: company_id,
           review_deadline: deadline
         },
         now
       )
       when is_binary(id) and is_binary(company_id) and company_id != "" do
    if match?(%DateTime{}, deadline) and DateTime.compare(deadline, now) == :gt,
      do: :ok,
      else: {:error, :stale_recovery_proposal}
  end

  defp valid_persisted_retry_approval(_, _), do: {:error, :stale_recovery_proposal}

  defp persisted_retry_payload(%BoardApproval{proposal_data: data, recovery_case_id: fk})
       when is_map(data) do
    case {Map.get(data, "action"), Map.get(data, "case_id"), Map.get(data, "fingerprint")} do
      {"retry", case_id, fingerprint}
      when is_binary(case_id) and is_binary(fingerprint) and case_id == fk ->
        {:ok, case_id, data}

      _ ->
        {:error, :stale_recovery_proposal}
    end
  end

  defp persisted_retry_payload(_), do: {:error, :stale_recovery_proposal}

  defp valid_case_linkage(
         %BoardApproval{company_id: company_id, recovery_case_id: _fk},
         %RecoveryCase{
           company_id: company_id,
           id: id,
           issue_id: case_issue_id,
           source_fingerprint: case_fingerprint,
           source_type: case_source_type,
           source_run_id: case_run_id,
           state: "escalated"
         },
         %{
           "case_id" => id,
           "fingerprint" => fingerprint,
           "issue_id" => issue_id,
           "source_type" => source_type,
           "source_run_id" => source_run_id
         }
       ) do
    if is_binary(fingerprint) and fingerprint == case_fingerprint and
         issue_id == case_issue_id and
         source_type == case_source_type and source_run_id == case_run_id do
      :ok
    else
      {:error, :stale_recovery_proposal}
    end
  end

  defp valid_case_linkage(_, _, _), do: {:error, :stale_recovery_proposal}

  defp valid_retry_issue(case_row, %Issue{} = issue, data) do
    cond do
      issue.status not in [:blocked, "blocked"] -> {:error, :stale_recovery_proposal}
      Map.get(data, "issue_id") != issue.id -> {:error, :stale_recovery_proposal}
      not retry_source_matches?(case_row, issue) -> {:error, :stale_recovery_proposal}
      true -> :ok
    end
  end

  defp resume_retry_issue(%RecoveryCase{} = case_row, %Issue{} = issue, _now) do
    # `resume_issue_runtime/2` is the existing public pause API.  The deferred
    # option keeps its optimistic-lock semantics while suppressing broadcasts
    # until the enclosing recovery transaction commits.
    resumed =
      if Issues.issue_runtime_paused?(issue) do
        case Issues.resume_issue_runtime(issue,
               actor: {"system", case_row.id},
               defer_side_effects: true
             ) do
          {:ok, updated} -> updated
          _ -> throw({:resume_failed, :stale_recovery_proposal})
        end
      else
        issue
      end

    expected_assignee =
      if case_row.source_type == "heartbeat_run" do
        snapshot_value(case_row.source_snapshot, "agent_id")
      else
        snapshot_value(case_row.source_snapshot, "assignee_id")
      end

    # The source snapshot has already been checked by valid_retry_issue/3. Keep
    # one final in-transaction ownership predicate before invoking the existing
    # exact CAS helper; a successor that changed the binding or assignee wins.
    if resumed.status in [:blocked, "blocked"] and
         resumed.company_id == issue.company_id and
         resumed.assignee_id == expected_assignee do
      case Issues.clear_checkout_lock_deferred(resumed, :todo) do
        {:ok, cleared} ->
          {:ok, cleared}

        {:error, _reason} ->
          {:error, :stale_recovery_proposal}
      end
    else
      {:error, :stale_recovery_proposal}
    end
  catch
    {:resume_failed, reason} -> {:error, reason}
  end

  defp snapshot_value(snapshot, key) when is_map(snapshot), do: Map.get(snapshot, key)
  defp snapshot_value(_, _), do: nil

  defp retry_child_fingerprint(%RecoveryCase{source_type: "issue_checkout"} = _case_row, issue),
    do: {:ok, Fingerprint.for_issue_checkout(issue)}

  defp retry_child_fingerprint(%RecoveryCase{source_type: "heartbeat_run"} = case_row, issue) do
    case Repo.get(Run, case_row.source_run_id) do
      %Run{} = run -> {:ok, Fingerprint.for_run(run, issue)}
      _ -> {:error, :stale_recovery_proposal}
    end
  end

  defp retry_child_fingerprint(case_row, _issue),
    do: {:ok, {case_row.source_fingerprint, case_row.source_snapshot}}

  defp canonical_source_id(
         %RecoveryCase{source_type: "heartbeat_run", source_run_id: run_id},
         _issue
       )
       when is_binary(run_id), do: run_id

  defp canonical_source_id(%RecoveryCase{source_type: "heartbeat_run"}, _), do: nil

  defp canonical_source_id(%RecoveryCase{source_type: "issue_checkout"}, %Issue{id: id}), do: id
  defp canonical_source_id(%RecoveryCase{source_id: source_id}, _), do: source_id

  defp insert_retry_child!(attrs) do
    case %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert() do
      {:ok, child} ->
        child

      {:error, changeset} ->
        # A concurrent approval/retry may have inserted the canonical child;
        # return that durable row rather than creating an alternate identity.
        if unique_constraint_error?(changeset) do
          existing =
            Repo.one(
              from c in RecoveryCase,
                where:
                  c.company_id == ^attrs.company_id and c.source_type == ^attrs.source_type and
                    c.source_id == ^attrs.source_id and c.state in ^RecoveryCase.active_states(),
                order_by: [desc: c.inserted_at]
            )

          if existing && existing.parent_case_id == attrs.parent_case_id &&
               existing.root_case_id == attrs.root_case_id &&
               existing.source_fingerprint == attrs.source_fingerprint do
            existing
          else
            Repo.rollback(:stale_recovery_proposal)
          end
        else
          Repo.rollback({:invalid_retry_child, changeset})
        end
    end
  end

  defp unique_constraint_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} ->
      Keyword.get(opts, :constraint) == :unique
    end)
  end

  defp unique_constraint_error?(_), do: false

  defp source_matches?(%RecoveryCase{source_type: "issue_checkout"} = case_row, issue),
    do: current_source_matches?(case_row, issue, nil)

  defp source_matches?(
         %RecoveryCase{
           source_type: "heartbeat_run",
           source_run_id: run_id
         } = case_row,
         issue
       )
       when is_binary(run_id) do
    case Repo.get(Run, run_id) do
      %Run{} = run ->
        current_source_matches?(case_row, run, issue)

      _ ->
        false
    end
  end

  defp source_matches?(_, _), do: false

  # The escalation itself moves the issue to `:blocked` and increments its
  # lock version. Retry therefore validates the durable pre-escalation
  # snapshot against that one expected transition, rather than comparing the
  # original source fingerprint to a deliberately changed issue status.
  defp retry_source_matches?(
         %RecoveryCase{
           source_type: "issue_checkout",
           source_fingerprint: source_fingerprint,
           source_snapshot: snapshot
         },
         %Issue{} = issue
       )
       when is_map(snapshot) do
    retry_issue_snapshot_matches?(snapshot, issue, "issue_checkout") and
      recomputed_original_checkout?(source_fingerprint, snapshot, issue)
  end

  defp retry_source_matches?(
         %RecoveryCase{
           source_type: "heartbeat_run",
           source_run_id: run_id,
           source_fingerprint: source_fingerprint,
           source_snapshot: snapshot
         },
         %Issue{} = issue
       )
       when is_binary(run_id) and is_map(snapshot) do
    with %Run{} = run <- Repo.get(Run, run_id),
         true <- run.company_id == issue.company_id,
         true <- run.issue_id == issue.id,
         true <- to_string(run.status) not in @terminal_run_statuses,
         true <- to_string(run.status) == snapshot["run_status"],
         true <- run.agent_id == snapshot["agent_id"],
         true <- retry_issue_snapshot_matches?(snapshot, issue, "heartbeat_run"),
         true <- recomputed_original_run?(source_fingerprint, snapshot, run, issue) do
      true
    else
      _ -> false
    end
  end

  defp retry_source_matches?(_, _), do: false

  defp retry_issue_snapshot_matches?(snapshot, %Issue{} = issue, source_type) do
    expected_assignee =
      if source_type == "heartbeat_run", do: snapshot["agent_id"], else: snapshot["assignee_id"]

    assignee_ok? = expected_assignee == id_value(issue.assignee_id)

    snapshot_complete?(snapshot, issue_snapshot_keys(source_type)) and
      snapshot["source_type"] == source_type and
      snapshot["issue_id"] == issue.id and
      snapshot["company_id"] == issue.company_id and
      assignee_ok? and
      snapshot["checkout_run_id"] == id_value(issue.checkout_run_id) and
      retry_lock_version_matches?(snapshot, issue)
  end

  defp snapshot_complete?(snapshot, keys) when is_map(snapshot) do
    Enum.all?(keys, &Map.has_key?(snapshot, &1))
  end

  defp snapshot_complete?(_, _), do: false

  defp retry_lock_version_matches?(snapshot, %Issue{status: status, lock_version: lock_version})
       when status in [:blocked, "blocked"] do
    source_status = snapshot["issue_status"]
    source_lock = snapshot["lock_version"] || snapshot["issue_lock_version"]

    expected_lock =
      if source_status in ["blocked", :blocked], do: source_lock, else: increment(source_lock)

    lock_version == expected_lock
  end

  defp retry_lock_version_matches?(_, _), do: false

  defp issue_checkout_snapshot_keys,
    do: [
      "version",
      "source_type",
      "issue_id",
      "company_id",
      "assignee_id",
      "issue_status",
      "checkout_liveness_at",
      "checkout_run_id",
      "lock_version"
    ]

  defp heartbeat_snapshot_keys,
    do: [
      "version",
      "source_type",
      "company_id",
      "run_id",
      "issue_id",
      "agent_id",
      "run_status",
      "liveness_at",
      "issue_status",
      "issue_lock_version",
      "lock_version",
      "checkout_run_id",
      "error_family"
    ]

  defp issue_snapshot_keys("issue_checkout"), do: issue_checkout_snapshot_keys()
  defp issue_snapshot_keys("heartbeat_run"), do: heartbeat_snapshot_keys()
  defp issue_snapshot_keys(_), do: []

  defp recomputed_original_checkout?(source_fingerprint, snapshot, issue) do
    synthetic = %{
      id: snapshot["issue_id"],
      company_id: snapshot["company_id"],
      assignee_id: snapshot["assignee_id"],
      status: snapshot["issue_status"],
      checkout_run_id: snapshot["checkout_run_id"],
      checked_out_at: snapshot["checkout_liveness_at"],
      lock_version: snapshot["lock_version"]
    }

    {fingerprint, _} = Fingerprint.for_issue_checkout(synthetic)
    fingerprint == source_fingerprint and issue.company_id == snapshot["company_id"]
  end

  defp recomputed_original_run?(source_fingerprint, snapshot, run, issue) do
    synthetic_issue = %{
      id: snapshot["issue_id"],
      company_id: snapshot["company_id"],
      status: snapshot["issue_status"],
      lock_version: snapshot["issue_lock_version"] || snapshot["lock_version"],
      checkout_run_id: snapshot["checkout_run_id"]
    }

    synthetic_run = %{
      id: snapshot["run_id"],
      company_id: snapshot["company_id"],
      issue_id: snapshot["issue_id"],
      agent_id: snapshot["agent_id"],
      status: snapshot["run_status"],
      last_heartbeat_at: snapshot["liveness_at"],
      inserted_at: snapshot["liveness_at"],
      error_reason: snapshot["error_family"]
    }

    {fingerprint, _} = Fingerprint.for_run(synthetic_run, synthetic_issue)

    fingerprint == source_fingerprint and
      run.id == snapshot["run_id"] and run.company_id == snapshot["company_id"] and
      run.issue_id == snapshot["issue_id"] and run.agent_id == snapshot["agent_id"] and
      to_string(run.status) == snapshot["run_status"] and
      Fingerprint.error_family(run.error_reason) == snapshot["error_family"] and
      issue.company_id == snapshot["company_id"]
  end

  defp increment(value) when is_integer(value), do: value + 1
  defp increment(_), do: nil

  defp id_value(nil), do: nil
  defp id_value(value) when is_binary(value), do: value

  @spec ensure_case(map()) :: {:ok, RecoveryCase.t()} | {:error, term()}
  def ensure_case(attrs) when is_map(attrs) do
    source_type = attrs[:source_type] || attrs["source_type"]
    issue_input = attrs[:issue] || attrs["issue"]
    run = attrs[:run] || attrs[:source_run] || attrs["run"] || attrs["source_run"]

    with {:ok, issue} <- load_issue(issue_input),
         :ok <- validate_input_scope(issue_input, issue),
         :ok <- validate_scope(issue, attrs, run),
         {:ok, fingerprint, snapshot, source_id, source_status, agent_id, source_run_id} <-
           source_details(source_type, issue, run) do
      with {:ok, policy} <- normalize_policy(attrs) do
        attrs = %{
          company_id: issue.company_id,
          issue_id: issue.id,
          agent_id: agent_id,
          source_run_id: source_run_id,
          source_type: source_type,
          source_id: source_id,
          source_status: source_status,
          source_fingerprint: fingerprint,
          fingerprint_version: Fingerprint.version(),
          source_snapshot: snapshot,
          max_attempts: policy.max_attempts,
          policy_snapshot: policy.snapshot
        }

        case do_ensure_case(attrs) do
          {:ok, row} ->
            {:ok, row}

          {:ok, row, superseded_id} ->
            publish_superseded_approval(superseded_id)
            {:ok, row}

          other ->
            other
        end
      end
    end
  rescue
    e in Ecto.ConstraintError ->
      if e.constraint == "recovery_cases_active_source_index" do
        attrs
        |> reload_active_case()
        |> case do
          {:ok, row} -> {:ok, row}
          _ -> {:error, e}
        end
      else
        {:error, e}
      end

    e in Ecto.QueryError ->
      {:error, e}
  end

  @doc "Claims one due recovery case using the durable lease mutex."
  @spec claim_due_case(RecoveryCase.t() | binary(), keyword()) ::
          {:ok, %{case: RecoveryCase.t(), attempt: RecoveryAttempt.t(), token: String.t()}}
          | {:error, atom()}
  def claim_due_case(case_or_id, opts \\ []) do
    claim_case(case_or_id, Keyword.put(opts, :due_only, true))
  end

  @spec claim_case(RecoveryCase.t() | binary(), keyword()) ::
          {:ok, %{case: RecoveryCase.t(), attempt: RecoveryAttempt.t(), token: String.t()}}
          | {:error, atom()}
  def claim_case(%RecoveryCase{id: id}, opts), do: claim_case(id, opts)

  def claim_case(id, opts) when is_binary(id) do
    with {:ok, _requested_policy} <- normalize_policy(opts) do
      now = option_now(opts)
      claimed_by = option_value(opts, :claimed_by) || node() |> to_string()

      result =
        Repo.transaction(fn ->
          case Repo.one(from c in RecoveryCase, where: c.id == ^id, lock: "FOR UPDATE") do
            nil ->
              Repo.rollback(:not_found)

            case_row ->
              with {:ok, policy} <- policy_for_case(case_row, opts) do
                lease_seconds = policy.lease_seconds

                cond do
                  case_row.state == "claimed" and
                      expired?(case_row.lease_expires_at, now) == false ->
                    Repo.rollback(:already_claimed)

                  case_row.state == "claimed" and case_row.attempt_count >= case_row.max_attempts ->
                    # A worker died after claiming the final attempt.  Do not
                    # leave this row forever in a rollback-only exhausted loop;
                    # hand it to the durable escalation pass.
                    expire_claimed_attempt(case_row, now)

                    Repo.update_all(
                      from(c in RecoveryCase, where: c.id == ^id),
                      set: [
                        state: "exhausted",
                        exhausted_at: case_row.exhausted_at || now,
                        claim_token: nil,
                        claimed_at: nil,
                        lease_expires_at: nil,
                        claimed_by: nil,
                        next_attempt_at: nil
                      ]
                    )

                    {:needs_escalation, Repo.get!(RecoveryCase, id)}

                  case_row.state == "exhausted" ->
                    {:needs_escalation, case_row}

                  case_row.state not in ["detected", "scheduled", "claimed"] ->
                    Repo.rollback(:not_claimable)

                  (option_value(opts, :due_only) == true and case_row.state == "detected" and
                     case_row.next_attempt_at) &&
                      DateTime.compare(case_row.next_attempt_at, now) == :gt ->
                    Repo.rollback(:not_due)

                  (case_row.state in ["detected", "scheduled"] and case_row.next_attempt_at) &&
                      DateTime.compare(case_row.next_attempt_at, now) == :gt ->
                    Repo.rollback(:not_due)

                  true ->
                    if case_row.state == "claimed" and expired?(case_row.lease_expires_at, now) do
                      # A lease takeover closes the previous attempt before a
                      # new attempt number is claimed. This keeps append-only
                      # history truthful after a worker crash.
                      expire_claimed_attempt(case_row, now)
                    end

                    attempt_no = case_row.attempt_count + 1

                    if attempt_no > case_row.max_attempts do
                      Repo.update_all(
                        from(c in RecoveryCase, where: c.id == ^id),
                        set: [state: "exhausted", exhausted_at: case_row.exhausted_at || now]
                      )

                      {:needs_escalation, Repo.get!(RecoveryCase, id)}
                    else
                      token = Ecto.UUID.generate()
                      claimed_at = now
                      expires = DateTime.add(now, lease_seconds, :second)

                      {1, _} =
                        Repo.update_all(
                          from(c in RecoveryCase, where: c.id == ^id),
                          set: [
                            state: "claimed",
                            attempt_count: attempt_no,
                            claim_token: token,
                            claimed_at: claimed_at,
                            lease_expires_at: expires,
                            claimed_by: claimed_by,
                            last_attempt_at: now
                          ]
                        )

                      attempt =
                        %RecoveryAttempt{}
                        |> RecoveryAttempt.changeset(%{
                          recovery_case_id: id,
                          attempt_no: attempt_no,
                          status: "claimed",
                          action: "retry",
                          source_fingerprint: case_row.source_fingerprint,
                          started_at: now,
                          node: claimed_by,
                          metadata: %{policy: policy.snapshot}
                        })
                        |> Repo.insert!()

                      updated = Repo.get!(RecoveryCase, id)
                      %{case: updated, attempt: attempt, token: token}
                    end
                end
              else
                _ -> Repo.rollback(:invalid_policy)
              end
          end
        end)

      case result do
        {:ok, {:needs_escalation, exhausted_case}} ->
          case exhaust_case(exhausted_case, reason: exhausted_case.last_error, now: now) do
            {:ok, %BoardApproval{}} -> {:error, :exhausted}
            {:ok, %RecoveryCase{state: "superseded"}} -> {:error, :superseded}
            {:error, reason} -> {:error, {:exhaustion_failed, reason}}
          end

        other ->
          other
      end
    end
  end

  @spec record_success(map(), term()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_success(lease, opts_or_result \\ %{}) do
    now = option_now(opts_or_result)
    complete_attempt(lease, "succeeded", nil, "recovered", now)
  end

  @spec record_superseded(map(), term()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_superseded(lease, opts_or_result \\ %{}) do
    now = option_now(opts_or_result)
    complete_attempt(lease, "skipped", nil, "superseded", now)
  end

  @spec record_failure(map(), term(), keyword()) :: {:ok, RecoveryCase.t()} | {:error, atom()}
  def record_failure(lease, reason, opts \\ []) do
    with now <- option_now(opts),
         {:ok, id, token, attempt} <- lease_parts(lease) do
      Repo.transaction(fn ->
        case Repo.one(
               from c in RecoveryCase,
                 where:
                   c.id == ^id and c.claim_token == ^token and c.state == "claimed" and
                     (is_nil(c.lease_expires_at) or c.lease_expires_at > ^now),
                 lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.rollback(:stale_claim)

          case_row ->
            policy =
              case policy_for_case(case_row, opts) do
                {:ok, value} -> value
                {:error, _} -> Repo.rollback(:invalid_policy)
              end

            attempt_no = attempt.attempt_no
            exhausted = attempt_no >= case_row.max_attempts

            {state, next_retry_at} =
              if exhausted,
                do: {"exhausted", nil},
                else:
                  {"scheduled", DateTime.add(now, retry_delay(attempt_no, policy, opts), :second)}

            error = bounded_error(reason)

            {attempt_count, _} =
              Repo.update_all(
                from(a in RecoveryAttempt,
                  where:
                    a.id == ^attempt.id and a.recovery_case_id == ^id and
                      a.attempt_no == ^attempt.attempt_no and a.status == "claimed"
                ),
                set: [
                  status: "failed",
                  completed_at: now,
                  error_reason: error,
                  next_retry_at: next_retry_at
                ]
              )

            if attempt_count == 0, do: Repo.rollback(:stale_claim)

            updates = [
              state: state,
              claim_token: nil,
              claimed_at: nil,
              lease_expires_at: nil,
              claimed_by: nil,
              last_error: error,
              next_attempt_at: next_retry_at
            ]

            updates = if exhausted, do: [{:exhausted_at, now} | updates], else: updates

            {case_count, _} =
              Repo.update_all(
                from(c in RecoveryCase, where: c.id == ^id and c.claim_token == ^token),
                set: updates
              )

            if case_count != 1, do: Repo.rollback(:stale_claim)

            Repo.get!(RecoveryCase, id)
        end
      end)
    end
  end

  @spec with_attempt(map() | RecoveryCase.t(), keyword(), (map() -> term())) ::
          {:ok, map()} | {:error, term()}
  def with_attempt(source, opts, callback) when is_function(callback, 1) do
    with {:ok, _policy} <- normalize_policy(opts),
         {:ok, case_row} <- ensure_source(source),
         {:ok, lease} <- claim_case(case_row, opts) do
      result =
        try do
          callback.(lease)
        rescue
          exception -> {:error, {:exception, exception}}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      outcome_result =
        case result do
          {:ok, value} ->
            {:ok, record_success(lease, opts), value, :recovered}

          {:error, :superseded} ->
            {:ok, record_superseded(lease, opts), result, :superseded}

          {:error, reason} ->
            failure = record_failure(lease, reason, opts)
            outcome = outcome_for_failure(lease)

            case {failure, outcome} do
              {{:ok, exhausted_case}, :exhausted} ->
                case exhaust_case(exhausted_case, Keyword.put(opts, :reason, reason)) do
                  {:ok, _approval} ->
                    final_case = Repo.get!(RecoveryCase, exhausted_case.id)

                    outcome =
                      if final_case.state == "superseded", do: :superseded, else: :exhausted

                    {:ok, {:ok, final_case}, result, outcome}

                  {:error, :stale_recovery_proposal} ->
                    {:ok, {:ok, Repo.get!(RecoveryCase, exhausted_case.id)}, result, :superseded}

                  {:error, reason} ->
                    {:error, {:exhaustion_failed, reason}}
                end

              {{:error, reason}, _} ->
                {:error, reason}

              _ ->
                {:ok, failure, result, outcome}
            end

          value ->
            {:ok, record_success(lease, opts), value, :recovered}
        end

      case outcome_result do
        {:error, reason} ->
          {:error, reason}

        {:ok, {:ok, updated}, value, outcome} ->
          {:ok, %{result: value, outcome: outcome, case: updated}}

        {:ok, {:error, reason}, _value, _outcome} ->
          {:error, reason}
      end
    end
  end

  @doc "Routes stale heartbeat-run recovery through a durable case and lease."
  @spec recover_stale_run(Run.t(), keyword()) ::
          {:ok, %{run: Run.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_stale_run(%Run{} = run, opts \\ []) do
    recover_run(run, :stale, opts)
  end

  @doc "Routes orphaned heartbeat-run recovery through a durable case and lease."
  @spec recover_orphaned_run(Run.t(), keyword()) ::
          {:ok, %{run: Run.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_orphaned_run(%Run{} = run, opts \\ []) do
    recover_run(run, :orphaned, opts)
  end

  @doc "Routes stale checkout recovery through durable cases and leases."
  @spec recover_orphaned_issue(Issue.t(), keyword()) ::
          {:ok, %{issue: Issue.t(), outcome: atom(), case: RecoveryCase.t()}} | {:error, term()}
  def recover_orphaned_issue(issue, opts \\ [])

  def recover_orphaned_issue(%Issue{} = issue, opts) do
    recovery_opts = Keyword.get(opts, :recovery_opts, opts)

    source =
      %{source_type: "issue_checkout", issue: issue}
      |> maybe_put_option(:max_attempts, opts)

    with {:ok, result} <-
           with_attempt(
             source,
             recovery_opts,
             fn lease ->
               case Issues.get_issue(issue.id) do
                 {:ok, current} ->
                   if current_source_matches?(lease.case, current, nil) and
                        current.company_id == issue.company_id do
                     recover_checkout(current, opts)
                   else
                     {:error, :superseded}
                   end

                 _ ->
                   {:error, :superseded}
               end
             end
           ) do
      {:ok,
       %{
         issue: checkout_result_issue(result.result, issue),
         outcome: result.outcome,
         case: result.case
       }}
    end
  end

  def recover_orphaned_issue(_issue, _opts), do: {:error, :issue_required}

  @doc "Processes a bounded batch of durable recovery cases that are due."
  @spec process_due(keyword()) :: map()
  def process_due(opts \\ [])

  def process_due(opts) when is_list(opts) do
    with {:ok, policy} <- normalize_policy(opts) do
      now = option_now(opts)
      limit = bounded_limit(Keyword.get(opts, :limit, 50))

      {ids, scan_error} =
        case Repo.transaction(fn ->
               Repo.all(
                 from c in RecoveryCase,
                   where:
                     (c.state == "detected" and
                        (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)) or
                       (c.state == "scheduled" and
                          (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)) or
                       (c.state == "claimed" and
                          not is_nil(c.lease_expires_at) and c.lease_expires_at <= ^now) or
                       c.state == "exhausted",
                   order_by: [asc: c.next_attempt_at, asc: c.inserted_at],
                   limit: ^limit,
                   select: c.id,
                   lock: "FOR UPDATE SKIP LOCKED"
               )
             end) do
          {:ok, ids} -> {ids, nil}
          {:error, reason} -> {[], reason}
        end

      stats =
        Enum.reduce(ids, empty_due_stats(), fn id, stats ->
          process_due_case(id, opts, policy, now, stats)
        end)

      result = Map.merge(stats, %{checked: length(ids), due: length(ids)})

      if scan_error do
        Map.put(result, :error, :database_unavailable)
        |> Map.update!(:errors, &[scan_error | &1])
      else
        result
      end
    else
      {:error, reason} ->
        Map.merge(empty_due_stats(), %{error: reason, errors: [reason]})
    end
  rescue
    error ->
      # A database outage must leave scheduled rows untouched and never clear
      # a checkout speculatively.  Keep the shape stable for watchdog callers.
      Logger.warning("Recovery due scan failed closed",
        component: "recovery",
        error: inspect(error)
      )

      Map.merge(empty_due_stats(), %{
        error: :database_unavailable,
        errors: [:database_unavailable]
      })
  end

  def process_due(_),
    do: Map.merge(empty_due_stats(), %{error: :invalid_options, errors: [:invalid_options]})

  defp empty_due_stats do
    %{
      checked: 0,
      due: 0,
      processed: 0,
      claimed: 0,
      recovered: 0,
      superseded: 0,
      scheduled: 0,
      exhausted: 0,
      failed: 0,
      errors: []
    }
  end

  defp process_due_case(id, opts, policy, now, stats) do
    claim_opts =
      opts
      |> Keyword.put(:now, now)

    # Let claim_case use the row's persisted lease snapshot after restart;
    # only an explicit bounded test/operator override should replace it.
    claim_opts =
      if option_value(opts, :lease_seconds),
        do: Keyword.put(claim_opts, :lease_seconds, policy.lease_seconds),
        else: claim_opts

    case claim_due_case(id, claim_opts) do
      {:ok, lease} ->
        stats = %{stats | claimed: stats.claimed + 1}
        process_due_lease(lease, Keyword.put(opts, :now, now), stats)

      {:error, :exhausted} ->
        %{stats | exhausted: stats.exhausted + 1}

      {:error, {:exhaustion_failed, reason}} ->
        %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}

      {:error, reason} when reason in [:already_claimed, :not_due, :not_claimable, :not_found] ->
        stats

      {:error, reason} ->
        %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp process_due_lease(
         %{case: %RecoveryCase{source_type: "heartbeat_run"} = case_row} = lease,
         opts,
         stats
       ) do
    result =
      with %Run{} = run <- Repo.get(Run, case_row.source_run_id),
           %Issue{} = issue <- Repo.get(Issue, case_row.issue_id),
           true <- current_source_matches?(case_row, run, issue),
           false <- source_live?(issue.id) do
        kind = if case_row.source_status in ["pending", "queued"], do: :orphaned, else: :stale

        HeartbeatEngine.recover_run_if_current(
          run,
          run_source_guard(case_row, kind),
          kind,
          now: option_now(opts)
        )
      else
        _ -> {:error, :superseded}
      end

    finish_due_result(lease, result, opts, stats)
  end

  defp process_due_lease(
         %{case: %RecoveryCase{source_type: "issue_checkout"} = case_row} = lease,
         opts,
         stats
       ) do
    result =
      case Repo.get(Issue, case_row.issue_id) do
        %Issue{status: status} = issue
        when status in [:todo, "todo"] and not is_nil(case_row.parent_case_id) ->
          # Approved retry children are durable markers for the dispatcher
          # wake.  Once the issue is reopened, consume the marker without
          # attempting a second destructive checkout clear.
          {:ok, issue}

        %Issue{} = issue ->
          with true <- current_source_matches?(case_row, issue, nil),
               false <- source_live?(issue.id),
               false <- active_checkout_run?(issue.id) do
            recover_checkout(issue)
          else
            _ -> {:error, :superseded}
          end

        _ ->
          {:error, :superseded}
      end

    finish_due_result(lease, result, opts, stats)
  end

  defp finish_due_result(lease, {:ok, _value}, opts, stats) do
    case record_success(lease, opts) do
      {:ok, _case} -> %{stats | processed: stats.processed + 1, recovered: stats.recovered + 1}
      {:error, reason} -> %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp finish_due_result(lease, {:error, :superseded}, opts, stats) do
    case record_superseded(lease, opts) do
      {:ok, _case} -> %{stats | processed: stats.processed + 1, superseded: stats.superseded + 1}
      {:error, reason} -> %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp finish_due_result(lease, {:error, reason}, opts, stats) do
    case record_failure(lease, reason, opts) do
      {:ok, updated} when updated.state == "exhausted" ->
        case exhaust_case(updated, reason: reason, now: option_now(opts)) do
          {:ok, %BoardApproval{}} ->
            %{stats | processed: stats.processed + 1, exhausted: stats.exhausted + 1}

          {:ok, %RecoveryCase{state: "superseded"}} ->
            %{stats | processed: stats.processed + 1, superseded: stats.superseded + 1}

          {:error, error} ->
            %{stats | failed: stats.failed + 1, errors: [error | stats.errors]}
        end

      {:ok, _updated} ->
        %{stats | processed: stats.processed + 1, scheduled: stats.scheduled + 1}

      {:error, error} ->
        %{stats | failed: stats.failed + 1, errors: [error | stats.errors]}
    end
  end

  @doc "Recovers all stale checked-out issues and returns stable aggregate counts."
  @spec recover_stale_checkouts(keyword()) :: %{
          checked: non_neg_integer(),
          released: non_neg_integer(),
          failed: non_neg_integer(),
          exhausted: non_neg_integer()
        }
  def recover_stale_checkouts(opts \\ []) do
    {result, _telemetry} = recover_stale_checkouts_with_telemetry(opts)
    result
  end

  @doc "Recovers stale checkout sources for one company through the durable facade."
  def recover_stale_checkouts_for_company(company_id, opts \\ [])

  def recover_stale_checkouts_for_company(company_id, opts) when is_binary(company_id) do
    issues = RuntimeOperations.stale_checked_out_issues(company_id, opts)
    recover_checkout_rows(issues, opts)
  end

  def recover_stale_checkouts_for_company(_, _),
    do: %{checked: 0, released: 0, failed: 0, exhausted: 0}

  @doc false
  def recover_stale_checkouts_with_telemetry(opts \\ []) do
    issues = RuntimeOperations.stale_checked_out_issues_all(opts)
    recover_checkout_rows_with_telemetry(issues, opts)
  rescue
    _error ->
      {%{checked: 0, released: 0, failed: 0, exhausted: 0}, %{cases_created: 0, attempts: 0}}
  end

  defp recover_checkout_rows(issues, opts) do
    {result, _telemetry} = recover_checkout_rows_with_telemetry(issues, opts)
    result
  end

  defp recover_checkout_rows_with_telemetry(issues, opts) do
    existing_sources = recovery_source_keys("issue_checkout")

    {result, telemetry, _seen_sources} =
      Enum.reduce(
        issues,
        {%{checked: 0, released: 0, failed: 0, exhausted: 0}, %{cases_created: 0, attempts: 0},
         existing_sources},
        fn issue, {acc, telemetry, seen_sources} ->
          acc = %{acc | checked: acc.checked + 1}

          case recover_orphaned_issue(issue, opts) do
            {:ok, %{outcome: :recovered, case: recovery_case}} ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {%{acc | released: acc.released + 1}, telemetry, seen_sources}

            {:ok, %{outcome: :exhausted, case: recovery_case}} ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {%{acc | exhausted: acc.exhausted + 1}, telemetry, seen_sources}

            {:ok, %{outcome: outcome, case: recovery_case}}
            when outcome in [:superseded, :scheduled] ->
              {telemetry, seen_sources} =
                update_recovery_telemetry(telemetry, seen_sources, recovery_case)

              {if(outcome == :scheduled, do: %{acc | failed: acc.failed + 1}, else: acc),
               telemetry, seen_sources}

            {:error, _reason} ->
              {%{acc | failed: acc.failed + 1}, telemetry, seen_sources}
          end
        end
      )

    {result, telemetry}
  end

  defp recovery_source_keys(source_type) do
    Repo.all(
      from c in RecoveryCase,
        where: c.source_type == ^source_type and c.state in ^RecoveryCase.active_states(),
        select: {c.source_type, c.source_id}
    )
    |> MapSet.new()
  end

  defp update_recovery_telemetry(telemetry, seen_sources, nil), do: {telemetry, seen_sources}

  defp update_recovery_telemetry(telemetry, seen_sources, %{source_type: type, source_id: id}) do
    source = {type, id}
    telemetry = %{telemetry | attempts: telemetry.attempts + 1}

    if MapSet.member?(seen_sources, source) do
      {telemetry, seen_sources}
    else
      {%{telemetry | cases_created: telemetry.cases_created + 1},
       MapSet.put(seen_sources, source)}
    end
  end

  defp recover_run(%Run{} = run, kind, opts) do
    source =
      %{source_type: "heartbeat_run", issue: nil, run: run}
      |> maybe_put_option(:max_attempts, opts)

    with {:ok, issue} <- Issues.get_issue(run.issue_id),
         {:ok, result} <-
           with_attempt(
             %{source | issue: issue},
             Keyword.get(opts, :recovery_opts, opts),
             fn lease ->
               current = Repo.get(Run, run.id)

               with %Run{} = current <- current,
                    {:ok, current_issue} <- Issues.get_issue(current.issue_id),
                    true <- current_source_matches?(lease.case, current, current_issue),
                    false <- source_live?(current.issue_id) do
                 callback_result =
                   HeartbeatEngine.recover_run_if_current(
                     current,
                     run_source_guard(lease.case, kind),
                     kind,
                     now: option_now(opts)
                   )

                 case callback_result do
                   {:error, {:invalid_status, _status}} -> {:error, :superseded}
                   {:ok, updated} -> {:ok, updated}
                   {:error, reason} -> {:error, reason}
                 end
               else
                 _ -> {:error, :superseded}
               end
             end
           ) do
      {:ok,
       %{
         run: run_result(result.result, run),
         outcome: result.outcome,
         case: result.case
       }}
    end
  end

  defp maybe_put_option(source, key, opts) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Map.put(source, key, value)
      :error -> source
    end
  end

  defp current_source_matches?(
         %RecoveryCase{source_type: "heartbeat_run"} = case_row,
         %Run{} = run,
         %Issue{} = issue
       ) do
    {current_fp, snapshot} = Fingerprint.for_run(run, issue)

    complete_v2_snapshot?(case_row, "liveness_at") and
      case_row.company_id == issue.company_id and case_row.company_id == run.company_id and
      case_row.issue_id == issue.id and case_row.issue_id == run.issue_id and
      case_row.source_id == run.id and case_row.source_run_id == run.id and
      case_row.agent_id == run.agent_id and case_row.source_status == to_string(run.status) and
      to_string(run.status) not in @terminal_run_statuses and
      case_row.source_snapshot["liveness_at"] == snapshot["liveness_at"] and
      case_row.source_fingerprint == current_fp
  end

  defp current_source_matches?(
         %RecoveryCase{source_type: "issue_checkout"} = case_row,
         %Issue{} = issue,
         _optional_issue
       ) do
    {current_fp, snapshot} = Fingerprint.for_issue_checkout(issue)

    complete_v2_snapshot?(case_row, "checkout_liveness_at") and
      case_row.company_id == issue.company_id and case_row.issue_id == issue.id and
      case_row.source_id == issue.id and case_row.agent_id == issue.assignee_id and
      case_row.source_run_id == issue.checkout_run_id and
      case_row.source_status == to_string(issue.status) and
      issue.status in [:in_progress, "in_progress"] and
      case_row.source_snapshot["checkout_liveness_at"] == snapshot["checkout_liveness_at"] and
      case_row.source_fingerprint == current_fp
  end

  defp current_source_matches?(_, _, _), do: false

  defp complete_v2_snapshot?(%RecoveryCase{} = case_row, liveness_key) do
    is_map(case_row.source_snapshot) and
      case_row.fingerprint_version == Fingerprint.version() and
      case_row.source_snapshot["version"] == Fingerprint.version() and
      is_binary(case_row.source_snapshot[liveness_key]) and
      case_row.source_snapshot[liveness_key] != ""
  end

  defp run_source_guard(%RecoveryCase{} = case_row, kind) do
    %{
      source_type: case_row.source_type,
      company_id: case_row.company_id,
      issue_id: case_row.issue_id,
      source_id: case_row.source_id,
      source_run_id: case_row.source_run_id,
      agent_id: case_row.agent_id,
      source_status: case_row.source_status,
      source_fingerprint: case_row.source_fingerprint,
      fingerprint_version: case_row.fingerprint_version,
      liveness_at: case_row.source_snapshot["liveness_at"],
      recovery_kind: kind
    }
  end

  defp source_live?(issue_id) when is_binary(issue_id) do
    case Orchestrator.whereis(issue_id) do
      pid when is_pid(pid) -> Process.alive?(pid) or live_adapter_worker?(issue_id)
      _ -> live_adapter_worker?(issue_id)
    end
  rescue
    _ -> true
  end

  defp source_live?(_), do: true

  defp run_result(%Run{} = run, _fallback), do: run
  defp run_result(_, fallback), do: fallback

  defp checkout_result_issue(%Issue{} = issue, _fallback), do: issue
  defp checkout_result_issue(_, fallback), do: fallback

  defp recover_checkout(%Issue{} = issue, _opts \\ []) do
    cond do
      issue.status not in [:in_progress, "in_progress"] ->
        {:error, :superseded}

      live_runtime?(issue.id) ->
        {:error, :superseded}

      active_checkout_run?(issue.id) ->
        {:error, :superseded}

      true ->
        with {:ok, current} <- checkout_snapshot(issue),
             :ok <- ensure_no_active_checkout_run(issue.id),
             :ok <- ensure_no_live_runtime(issue.id) do
          release_result =
            Workspaces.cancel_and_release_for_issue(current, %{
              reason: "orphan_issue_reclaim",
              company_id: current.company_id
            })

          case release_result do
            {:error, reason} ->
              {:error, reason}

            :ok ->
              with :ok <-
                     ensure_no_active_checkout_run(issue.id),
                   {:ok, current_after} <- checkout_snapshot(issue),
                   :ok <- ensure_no_live_runtime(issue.id) do
                case Issues.clear_checkout_lock(current_after, :todo) do
                  {:ok, cleared} -> {:ok, cleared}
                  {:error, _reason} -> {:error, :superseded}
                end
              else
                _ -> {:error, :superseded}
              end
          end
        else
          _ -> {:error, :superseded}
        end
    end
  end

  defp checkout_snapshot(%Issue{} = issue) do
    case Issues.get_issue(issue.id) do
      {:ok, current} ->
        if current.status in [:in_progress, "in_progress"] and
             current.lock_version == issue.lock_version and
             current.checkout_run_id == issue.checkout_run_id and
             current.checked_out_at == issue.checked_out_at do
          {:ok, current}
        else
          :error
        end

      _ ->
        :error
    end
  end

  defp ensure_no_active_checkout_run(issue_id),
    do: if(active_checkout_run?(issue_id), do: {:error, :active_run}, else: :ok)

  defp ensure_no_live_runtime(issue_id),
    do: if(live_runtime?(issue_id), do: {:error, :live_runtime}, else: :ok)

  defp active_checkout_run?(issue_id) do
    Repo.exists?(
      from r in Run,
        where: r.issue_id == ^issue_id and r.status in ["pending", "queued", "running"]
    )
  rescue
    _error -> true
  end

  defp live_runtime?(issue_id) do
    case Orchestrator.whereis(issue_id) do
      nil ->
        case Cympho.AdapterSessions.owners_for_issue(issue_id) do
          {:ok, []} -> false
          {:ok, [_ | _]} -> true
          {:error, :not_started} -> true
        end

      pid ->
        Process.alive?(pid) or live_adapter_worker?(issue_id)
    end
  end

  defp live_adapter_worker?(issue_id) do
    case Cympho.AdapterSessions.owners_for_issue(issue_id) do
      {:ok, []} -> false
      {:ok, [_ | _]} -> true
      {:error, :not_started} -> true
    end
  end

  defp ensure_source(%RecoveryCase{} = row), do: {:ok, row}
  defp ensure_source(source), do: ensure_case(source)

  defp complete_attempt(lease, status, error, state, now) do
    with {:ok, id, token, attempt} <- lease_parts(lease) do
      Repo.transaction(fn ->
        case Repo.one(
               from c in RecoveryCase,
                 where:
                   c.id == ^id and c.claim_token == ^token and c.state == "claimed" and
                     (is_nil(c.lease_expires_at) or c.lease_expires_at > ^now),
                 lock: "FOR UPDATE"
             ) do
          nil ->
            Repo.rollback(:stale_claim)

          _case_row ->
            {attempt_count, _} =
              Repo.update_all(
                from(a in RecoveryAttempt,
                  where:
                    a.id == ^attempt.id and a.recovery_case_id == ^id and
                      a.attempt_no == ^attempt.attempt_no and a.status == "claimed"
                ),
                set: [status: status, completed_at: now, error_reason: error]
              )

            if attempt_count != 1, do: Repo.rollback(:stale_claim)

            updates = [
              state: state,
              claim_token: nil,
              claimed_at: nil,
              lease_expires_at: nil,
              claimed_by: nil,
              next_attempt_at: nil
            ]

            updates = if state == "recovered", do: [{:recovered_at, now} | updates], else: updates

            {case_count, _} =
              Repo.update_all(
                from(c in RecoveryCase, where: c.id == ^id and c.claim_token == ^token),
                set: updates
              )

            if case_count != 1, do: Repo.rollback(:stale_claim)

            Repo.get!(RecoveryCase, id)
        end
      end)
    end
  end

  defp lease_parts(%{
         case: %RecoveryCase{id: id},
         token: token,
         attempt: %RecoveryAttempt{} = attempt
       }),
       do: {:ok, id, token, attempt}

  defp lease_parts(_), do: {:error, :invalid_lease}

  defp outcome_for_failure(%{
         case: %RecoveryCase{max_attempts: max},
         attempt: %RecoveryAttempt{attempt_no: no}
       })
       when no >= max, do: :exhausted

  defp outcome_for_failure(_), do: :scheduled

  defp load_issue(%Issue{id: id}) when is_binary(id) do
    case Repo.get(Issue, id) do
      nil -> {:error, :issue_not_found}
      issue -> {:ok, issue}
    end
  end

  defp load_issue(%{id: id}) when is_binary(id),
    do: if(issue = Repo.get(Issue, id), do: {:ok, issue}, else: {:error, :issue_not_found})

  defp load_issue(%{"id" => id}) when is_binary(id),
    do: if(issue = Repo.get(Issue, id), do: {:ok, issue}, else: {:error, :issue_not_found})

  defp load_issue(_), do: {:error, :issue_required}

  defp validate_input_scope(input, %Issue{company_id: company_id}) do
    case Map.get(input, :company_id) || Map.get(input, "company_id") do
      ^company_id when is_binary(company_id) and byte_size(company_id) > 0 -> :ok
      _ -> {:error, :company_scope_required}
    end
  end

  defp validate_scope(%Issue{company_id: company_id}, attrs, run)
       when is_binary(company_id) and byte_size(company_id) > 0 do
    requested = attrs[:company_id] || attrs["company_id"]

    cond do
      requested && requested != company_id ->
        {:error, :company_scope_required}

      run &&
          (run_field(run, :issue_id) != attrs_issue_id(attrs) ||
             run_field(run, :company_id) != company_id) ->
        {:error, :company_scope_required}

      true ->
        :ok
    end
  end

  defp validate_scope(_, _, _), do: {:error, :company_scope_required}

  defp attrs_issue_id(attrs) do
    issue = attrs[:issue] || attrs["issue"]
    field(issue, :id)
  end

  defp run_field(run, key), do: Map.get(run, key) || Map.get(run, Atom.to_string(key))

  defp source_details("issue_checkout", issue, _run) do
    {fingerprint, snapshot} = Fingerprint.for_issue_checkout(issue)

    if is_binary(snapshot["checkout_liveness_at"]) do
      {:ok, fingerprint, snapshot, field(issue, :id), to_string(field(issue, :status)),
       field(issue, :assignee_id), field(issue, :checkout_run_id)}
    else
      {:error, :invalid_issue_source}
    end
  end

  defp source_details("heartbeat_run", issue, run) when is_map(run) do
    run_id = field(run, :id)
    run_status = field(run, :status)
    issue_id = field(run, :issue_id)
    company_id = field(run, :company_id)

    cond do
      not is_binary(run_id) or run_id == "" ->
        {:error, :invalid_run_source}

      is_nil(run_status) or run_status == "" ->
        {:error, :invalid_run_source}

      issue_id != field(issue, :id) ->
        {:error, :company_scope_required}

      company_id != field(issue, :company_id) ->
        {:error, :company_scope_required}

      true ->
        {fingerprint, snapshot} = Fingerprint.for_run(run, issue)
        source_run_id = if match?(%Run{}, run), do: run_id, else: nil

        if is_binary(snapshot["liveness_at"]) do
          {:ok, fingerprint, snapshot, run_id, to_string(run_status), field(run, :agent_id),
           source_run_id}
        else
          {:error, :invalid_run_source}
        end
    end
  end

  defp source_details("heartbeat_run", _issue, _), do: {:error, :run_required}
  defp source_details(_, _, _), do: {:error, :invalid_source_type}

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_, _), do: nil

  defp do_ensure_case(attrs, attempt \\ 0)

  defp do_ensure_case(attrs, attempt) when attempt < 2 do
    result =
      Repo.transaction(fn ->
        active =
          Repo.one(
            from c in RecoveryCase,
              where:
                c.company_id == ^attrs.company_id and c.source_type == ^attrs.source_type and
                  c.source_id == ^attrs.source_id and c.state in ^RecoveryCase.active_states(),
              order_by: [desc: c.inserted_at],
              lock: "FOR UPDATE"
          )

        cond do
          active && active.source_fingerprint == attrs.source_fingerprint ->
            active

          active ->
            Repo.update_all(from(c in RecoveryCase, where: c.id == ^active.id),
              set: [state: "superseded", resolved_at: DateTime.utc_now()]
            )

            # A pending proposal for the old fingerprint cannot remain
            # executable after its source is superseded.
            Repo.update_all(
              from(a in BoardApproval,
                where: a.recovery_case_id == ^active.id and a.status == "pending"
              ),
              set: [status: "cancelled", decision_reasoning: "Recovery source superseded"]
            )

            case insert_case(attrs, active) do
              {:ok, row} ->
                {:superseded, active.id, row}

              {:error, {:unique_conflict, changeset}} ->
                Repo.rollback({:unique_conflict, changeset})

              {:error, reason} ->
                Repo.rollback(reason)
            end

          true ->
            case insert_case(attrs, nil) do
              {:ok, row} ->
                row

              {:error, {:unique_conflict, changeset}} ->
                Repo.rollback({:unique_conflict, changeset})

              {:error, reason} ->
                Repo.rollback(reason)
            end
        end
      end)

    case result do
      {:ok, {:superseded, superseded_id, row}} ->
        {:ok, row, superseded_id}

      {:ok, row} ->
        {:ok, row}

      {:error, {:unique_conflict, _changeset}} ->
        case reload_active_case(attrs) do
          {:ok, row} ->
            if row.source_fingerprint == attrs.source_fingerprint do
              {:ok, row}
            else
              do_ensure_case(attrs, attempt + 1)
            end

          _ ->
            # The historical identity index may have won while the active
            # row was concurrently superseded. Reuse an exact historical row
            # only when it already represents this fingerprint; otherwise
            # retry the active-lock dance once more and fail closed.
            case Repo.one(
                   from c in RecoveryCase,
                     where:
                       c.company_id == ^attrs.company_id and
                         c.source_type == ^attrs.source_type and
                         c.source_id == ^attrs.source_id and
                         c.source_fingerprint == ^attrs.source_fingerprint,
                     order_by: [desc: c.inserted_at]
                 ) do
              %RecoveryCase{} = row -> {:ok, row}
              _ -> do_ensure_case(attrs, attempt + 1)
            end
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_ensure_case(_attrs, _attempt), do: {:error, :concurrent_conflict}

  defp insert_case(attrs, parent) do
    root_id = if parent, do: parent.root_case_id || parent.id

    attrs = Map.merge(attrs, %{parent_case_id: parent && parent.id, root_case_id: root_id})

    case %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert() do
      {:ok, row} ->
        if is_nil(root_id),
          do:
            Repo.update_all(from(c in RecoveryCase, where: c.id == ^row.id),
              set: [root_case_id: row.id]
            )

        {:ok, Repo.get!(RecoveryCase, row.id)}

      {:error, changeset} ->
        if unique_constraint_error?(changeset),
          do: {:error, {:unique_conflict, changeset}},
          else: {:error, changeset}
    end
  end

  defp reload_active_case(attrs) do
    source_type = attrs[:source_type] || attrs["source_type"]

    with {:ok, issue} <- load_issue(attrs[:issue] || attrs["issue"]) do
      run = attrs[:run] || attrs[:source_run] || attrs["run"] || attrs["source_run"]

      source_id =
        if source_type == "heartbeat_run",
          do: run_field(run, :id),
          else: issue.id

      case Repo.one(
             from c in RecoveryCase,
               where:
                 c.company_id == ^issue.company_id and c.source_type == ^source_type and
                   c.source_id == ^source_id and c.state in ^RecoveryCase.active_states()
           ) do
        nil -> {:error, :not_found}
        row -> {:ok, row}
      end
    end
  end

  defp expired?(nil, _), do: true
  defp expired?(expires, now), do: DateTime.compare(expires, now) != :gt

  defp expire_claimed_attempt(%RecoveryCase{id: case_id, attempt_count: attempt_no}, now) do
    # Only the currently numbered attempt can be leased for this case. If a
    # previous callback already completed it, the update is intentionally a
    # no-op; otherwise close the abandoned lease as a failed attempt so a
    # takeover cannot leave an immortal `claimed` history row.
    Repo.update_all(
      from(a in RecoveryAttempt,
        where:
          a.recovery_case_id == ^case_id and a.attempt_no == ^attempt_no and
            a.status == "claimed"
      ),
      set: [
        status: "failed",
        completed_at: now,
        error_reason: "lease_expired",
        next_retry_at: now
      ]
    )

    :ok
  end

  defp retry_delay(attempt_no, policy, opts) do
    # Explicit test/operator overrides remain supported, but they are always
    # validated by normalize_policy/1 and therefore cannot widen the durable
    # ten-minute delay cap. On restart, the case snapshot supplies the values
    # when no override is passed.
    base = option_value(opts, :base_delay) || policy.base_delay
    cap = option_value(opts, :max_delay) || policy.max_delay
    min(base * Integer.pow(2, max(attempt_no - 1, 0)), cap)
  end

  @max_policy_attempts 3
  @max_policy_delay_seconds 600
  @max_policy_lease_seconds 600

  defp normalize_policy(opts) when is_list(opts) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_policy_attempts)
    base_delay = Keyword.get(opts, :base_delay, 60)
    max_delay = Keyword.get(opts, :max_delay, @max_policy_delay_seconds)
    lease_seconds = Keyword.get(opts, :lease_seconds, @lease_seconds)

    valid? =
      is_integer(max_attempts) and max_attempts > 0 and max_attempts <= @max_policy_attempts and
        is_integer(base_delay) and base_delay > 0 and base_delay <= @max_policy_delay_seconds and
        is_integer(max_delay) and max_delay >= base_delay and
        max_delay <= @max_policy_delay_seconds and is_integer(lease_seconds) and
        lease_seconds > 0 and lease_seconds <= @max_policy_lease_seconds

    if valid? do
      {:ok,
       %{
         max_attempts: max_attempts,
         base_delay: base_delay,
         max_delay: max_delay,
         lease_seconds: lease_seconds,
         snapshot: %{
           "max_attempts" => max_attempts,
           "base_delay_seconds" => base_delay,
           "max_delay_seconds" => max_delay,
           "lease_seconds" => lease_seconds
         }
       }}
    else
      {:error, :invalid_policy}
    end
  end

  defp normalize_policy(opts) when is_map(opts) do
    normalize_policy(
      max_attempts:
        Map.get(opts, :max_attempts, Map.get(opts, "max_attempts", @max_policy_attempts)),
      base_delay: Map.get(opts, :base_delay, Map.get(opts, "base_delay", 60)),
      max_delay: Map.get(opts, :max_delay, Map.get(opts, "max_delay", @max_policy_delay_seconds)),
      lease_seconds: Map.get(opts, :lease_seconds, Map.get(opts, "lease_seconds", @lease_seconds))
    )
  end

  defp normalize_policy(_), do: {:error, :invalid_policy}

  # A case snapshots its effective policy at detection time. Later calls may
  # supply bounded overrides (used by deterministic tests), but omitted values
  # must come from that snapshot rather than silently reverting to process
  # defaults after a restart.
  defp policy_for_case(%RecoveryCase{} = case_row, opts) do
    snapshot = normalize_policy_snapshot(case_row.policy_snapshot)

    snapshot_max = Map.get(snapshot, :max_attempts, case_row.max_attempts || @max_policy_attempts)

    if snapshot_max != case_row.max_attempts do
      {:error, :invalid_policy}
    else
      policy_for_case_values(case_row, snapshot, opts)
    end
  end

  defp policy_for_case_values(%RecoveryCase{} = case_row, snapshot, opts) do
    explicit_max = option_value(opts, :max_attempts)

    if not is_nil(explicit_max) and explicit_max != case_row.max_attempts do
      {:error, :invalid_policy}
    else
      values = %{
        max_attempts: case_row.max_attempts || @max_policy_attempts,
        base_delay: Map.get(snapshot, :base_delay, 60),
        max_delay: Map.get(snapshot, :max_delay, @max_policy_delay_seconds),
        lease_seconds: Map.get(snapshot, :lease_seconds, @lease_seconds)
      }

      values =
        Enum.reduce([:base_delay, :max_delay, :lease_seconds], values, fn key, acc ->
          case option_value(opts, key) do
            nil -> acc
            value -> Map.put(acc, key, value)
          end
        end)

      normalize_policy(values)
    end
  end

  defp option_value(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp option_value(opts, key) when is_map(opts),
    do: Map.get(opts, key, Map.get(opts, to_string(key)))

  defp option_value(_, _), do: nil

  defp normalize_policy_snapshot(snapshot) when is_map(snapshot) do
    %{
      max_attempts: Map.get(snapshot, :max_attempts, Map.get(snapshot, "max_attempts")),
      base_delay: Map.get(snapshot, :base_delay, Map.get(snapshot, "base_delay_seconds")),
      max_delay: Map.get(snapshot, :max_delay, Map.get(snapshot, "max_delay_seconds")),
      lease_seconds: Map.get(snapshot, :lease_seconds, Map.get(snapshot, "lease_seconds"))
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_policy_snapshot(_), do: %{}

  defp policy_snapshot(max_attempts, opts) do
    case normalize_policy(Keyword.put(opts, :max_attempts, max_attempts)) do
      {:ok, policy} -> policy.snapshot
      _ -> %{"max_attempts" => max_attempts}
    end
  end

  defp bounded_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp bounded_limit(_), do: 50

  defp bounded_attempt_history(case_id) do
    Repo.all(
      from a in RecoveryAttempt,
        where: a.recovery_case_id == ^case_id,
        order_by: [asc: a.attempt_no],
        limit: 10,
        select: %{
          "attempt_no" => a.attempt_no,
          "status" => a.status,
          "action" => a.action,
          "error_reason" => a.error_reason,
          "started_at" => a.started_at,
          "completed_at" => a.completed_at
        }
    )
    |> Enum.map(fn row ->
      Enum.map(row, fn {key, value} -> {key, safe_history_value(value)} end)
      |> Map.new()
    end)
  rescue
    _ -> []
  end

  defp safe_history_value(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp safe_history_value(value) when is_binary(value) and byte_size(value) > 255,
    do: binary_part(value, 0, 255)

  defp safe_history_value(value), do: value

  defp option_now(opts) when is_list(opts),
    do: Keyword.get(opts, :now, DateTime.utc_now() |> DateTime.truncate(:second))

  defp option_now(%{now: now}), do: now
  defp option_now(%{"now" => now}), do: now
  defp option_now(_), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp review_deadline(now) do
    wall_now = DateTime.utc_now() |> DateTime.truncate(:second)
    base = if DateTime.compare(now, wall_now) == :gt, do: now, else: wall_now
    DateTime.add(base, 7 * 24 * 3600, :second)
  end

  defp bounded_error(nil), do: nil

  defp bounded_error(reason) do
    text = inspect(reason, limit: 20) |> String.downcase()

    cond do
      String.contains?(text, ["timeout", "timed out"]) -> "timeout"
      String.contains?(text, ["auth", "credential", "token", "secret"]) -> "authentication"
      String.contains?(text, ["rate", "429", "thrott"]) -> "rate_limited"
      String.contains?(text, ["network", "connect", "econn"]) -> "network"
      String.contains?(text, ["cancel"]) -> "cancelled"
      true -> "unknown"
    end
  end
end
