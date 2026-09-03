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
  @terminal_recovery_approval_statuses ~w(denied expired cancelled)
  @policy_option_keys [:max_attempts, :base_delay, :max_delay, :lease_seconds]

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

        case policy_for_case(locked, []) do
          {:ok, _policy} -> :ok
          {:error, :invalid_policy} -> Repo.rollback(:invalid_policy)
        end

        existing_approval =
          Repo.one(
            from a in BoardApproval,
              where: a.recovery_case_id == ^locked.id,
              lock: "FOR UPDATE"
          )

        issue =
          case Repo.one(from i in Issue, where: i.id == ^locked.issue_id, lock: "FOR UPDATE") do
            %Issue{} = row -> row
            nil -> Repo.rollback(:not_found)
          end

        cond do
          not approval_scope_matches?(existing_approval, locked) ->
            Repo.rollback(:invalid_recovery_approval)

          locked.state in ["recovered", "resolved", "superseded"] ->
            {:historical, locked}

          locked.state not in ["exhausted", "escalated"] ->
            Repo.rollback(:case_not_exhausted)

          recovery_source_deferred?(locked, issue, now) ->
            Repo.rollback(:recovery_deferred)

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

  @doc false
  def resolve_approval_case_locked(%BoardApproval{} = approval, reason) do
    with :ok <- validate_resolution_approval(approval),
         %RecoveryCase{} = case_row <- lock_linked_recovery_case(approval.recovery_case_id),
         :ok <- validate_resolution_company(approval, case_row) do
      if case_row.state in RecoveryCase.active_states() do
        now = DateTime.utc_now() |> DateTime.truncate(:second)
        resolution_note = bounded_resolution_note(reason)

        changeset =
          case_row
          |> Ecto.Changeset.change(%{
            state: "resolved",
            resolved_at: now,
            resolution_note: resolution_note,
            claim_token: nil,
            claimed_at: nil,
            lease_expires_at: nil,
            claimed_by: nil,
            next_attempt_at: nil
          })
          |> Ecto.Changeset.validate_length(:resolution_note,
            count: :codepoints,
            max: RecoveryCase.resolution_note_max_length()
          )
          |> Ecto.Changeset.check_constraint(:resolution_note,
            name: :recovery_cases_resolution_note_size_check
          )

        case Repo.update(changeset) do
          {:ok, _updated} ->
            {:changed,
             %{
               approval: approval,
               recovery_case: Repo.get!(RecoveryCase, case_row.id),
               resolution: approval.status
             }}

          {:error, changeset} ->
            {:error, changeset}
        end
      else
        :unchanged
      end
    else
      nil -> resolution_scope_error(approval, :recovery_case_id, "does not exist")
      {:error, _reason} = error -> error
    end
  end

  def resolve_approval_case_locked(_value, _reason) do
    {:error,
     %Ecto.Changeset{}
     |> Ecto.Changeset.add_error(:recovery_case_id, "must be a persisted recovery approval")}
  end

  @doc false
  def publish_approval_resolution(
        {:changed,
         %{
           approval: %BoardApproval{} = approval,
           recovery_case: %RecoveryCase{state: "resolved"} = case_row,
           resolution: status
         }}
      ) do
    approval = Repo.preload(approval, [:requested_by, :company])
    company_id = approval.company_id

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
  end

  def publish_approval_resolution(:unchanged), do: :ok

  @doc "Resolves a recovery case when its board approval is denied, expired, or cancelled."
  def handle_approval_resolution(%BoardApproval{id: approval_id}) when is_binary(approval_id) do
    result =
      Repo.transaction(fn ->
        case Repo.get(BoardApproval, approval_id) do
          %BoardApproval{
            category: "stranded_work_recovery",
            status: status,
            recovery_case_id: recovery_case_id
          }
          when status in @terminal_recovery_approval_statuses and
                 is_binary(recovery_case_id) ->
            _ = lock_linked_recovery_case(recovery_case_id)

            persisted =
              Repo.one(
                from a in BoardApproval,
                  where: a.id == ^approval_id,
                  lock: "FOR UPDATE"
              )

            case persisted do
              %BoardApproval{
                category: "stranded_work_recovery",
                status: locked_status,
                recovery_case_id: ^recovery_case_id
              }
              when locked_status in @terminal_recovery_approval_statuses ->
                case resolve_approval_case_locked(persisted, persisted.decision_reasoning) do
                  {:error, reason} -> Repo.rollback(reason)
                  effect -> effect
                end

              %BoardApproval{status: locked_status}
              when locked_status not in @terminal_recovery_approval_statuses ->
                :unchanged

              %BoardApproval{} ->
                rollback_resolution_scope(
                  persisted,
                  :recovery_case_id,
                  "changed while locking the approval"
                )

              nil ->
                :unchanged
            end

          _ ->
            :unchanged
        end
      end)

    case result do
      {:ok, effect} ->
        _ = publish_approval_resolution(effect)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def handle_approval_resolution(_), do: :ok

  defp validate_resolution_approval(%BoardApproval{
         __meta__: %Ecto.Schema.Metadata{state: :loaded},
         id: id,
         category: "stranded_work_recovery",
         status: status,
         recovery_case_id: recovery_case_id,
         company_id: company_id
       })
       when is_binary(id) and status in @terminal_recovery_approval_statuses and
              is_binary(recovery_case_id) and is_binary(company_id),
       do: :ok

  defp validate_resolution_approval(%BoardApproval{__meta__: %{state: state}} = approval)
       when state != :loaded,
       do:
         resolution_scope_error(
           approval,
           :recovery_case_id,
           "must be a persisted recovery approval"
         )

  defp validate_resolution_approval(%BoardApproval{category: category} = approval)
       when category != "stranded_work_recovery",
       do: resolution_scope_error(approval, :category, "must be stranded_work_recovery")

  defp validate_resolution_approval(%BoardApproval{status: status} = approval)
       when status not in @terminal_recovery_approval_statuses,
       do: resolution_scope_error(approval, :status, "must be denied, expired, or cancelled")

  defp validate_resolution_approval(%BoardApproval{recovery_case_id: id} = approval)
       when not is_binary(id),
       do: resolution_scope_error(approval, :recovery_case_id, "is required")

  defp validate_resolution_approval(%BoardApproval{} = approval),
    do: resolution_scope_error(approval, :company_id, "is required")

  defp lock_linked_recovery_case(case_id) do
    Repo.one(
      from c in RecoveryCase,
        where: c.id == ^case_id,
        lock: "FOR UPDATE"
    )
  end

  defp validate_resolution_company(
         %BoardApproval{company_id: company_id},
         %RecoveryCase{company_id: company_id}
       ),
       do: :ok

  defp validate_resolution_company(%BoardApproval{} = approval, %RecoveryCase{}) do
    resolution_scope_error(
      approval,
      :recovery_case_id,
      "must belong to the approval company"
    )
  end

  defp resolution_scope_error(%BoardApproval{} = approval, field, message) do
    {:error,
     approval
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(field, message)}
  end

  defp rollback_resolution_scope(%BoardApproval{} = approval, field, message) do
    {:error, changeset} = resolution_scope_error(approval, field, message)
    Repo.rollback(changeset)
  end

  defp bounded_resolution_note(nil), do: nil

  defp bounded_resolution_note(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" ->
        nil

      note ->
        note
        |> String.codepoints()
        |> Enum.take(RecoveryCase.resolution_note_max_length())
        |> Enum.join()
    end
  end

  defp bounded_resolution_note(_reason), do: nil

  @doc "Applies an approved stranded-work recovery retry exactly once."
  def apply_board_action(approval, opts \\ [])

  def apply_board_action(%BoardApproval{id: approval_id} = _caller, opts)
      when is_binary(approval_id) do
    defer_side_effects? = Keyword.get(opts, :defer_side_effects, false)
    now = option_now(opts)

    result =
      Repo.transaction(fn ->
        # The caller struct is only an address. Read the persisted approval
        # without a lock to locate its case, then acquire the canonical
        # case -> approval -> issue lock order and revalidate the locked row.
        locator = Repo.get(BoardApproval, approval_id)

        case_id =
          case locator do
            %BoardApproval{recovery_case_id: id} when is_binary(id) -> id
            _ -> Repo.rollback(:stale_recovery_proposal)
          end

        case_row =
          Repo.one(from c in RecoveryCase, where: c.id == ^case_id, lock: "FOR UPDATE")

        persisted =
          Repo.one(
            from a in BoardApproval,
              where: a.id == ^approval_id,
              lock: "FOR UPDATE"
          )

        with %RecoveryCase{} = case_row <- case_row,
             %BoardApproval{recovery_case_id: ^case_id} = persisted <- persisted,
             :ok <- valid_persisted_retry_approval(persisted, now),
             {:ok, ^case_id, data} <- persisted_retry_payload(persisted),
             :ok <- valid_case_linkage(persisted, case_row, data),
             %Issue{} = issue <-
               Repo.one(from i in Issue, where: i.id == ^case_row.issue_id, lock: "FOR UPDATE"),
             :ok <- valid_retry_issue(case_row, issue, data),
             {:ok, policy} <- policy_for_case(case_row, []) do
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
            policy_snapshot: policy.snapshot,
            max_attempts: policy.max_attempts,
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
    case %RecoveryCase{} |> RecoveryCase.changeset(attrs) |> Repo.insert(mode: :savepoint) do
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
               existing.source_fingerprint == attrs.source_fingerprint &&
               existing.max_attempts == attrs.max_attempts &&
               retry_child_policy_matches?(existing, attrs) do
            existing
          else
            Repo.rollback(:stale_recovery_proposal)
          end
        else
          Repo.rollback({:invalid_retry_child, changeset})
        end
    end
  end

  defp retry_child_policy_matches?(%RecoveryCase{} = existing, attrs) do
    with {:ok, existing_policy} <- policy_for_case(existing, []),
         requested <- normalize_policy_snapshot(attrs.policy_snapshot),
         true <- map_size(requested) == length(@policy_option_keys),
         {:ok, requested_policy} <- normalize_policy(requested) do
      existing_policy.snapshot === requested_policy.snapshot
    else
      _ -> false
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

  defp recovery_source_deferred?(
         %RecoveryCase{source_type: "heartbeat_run", source_run_id: run_id},
         %Issue{} = issue,
         now
       )
       when is_binary(run_id) and is_struct(now, DateTime) do
    case Repo.get(Run, run_id) do
      %Run{} = run when run.issue_id == issue.id -> HeartbeatEngine.recovery_deferred?(run, now)
      _ -> false
    end
  end

  defp recovery_source_deferred?(%RecoveryCase{source_type: "issue_checkout"}, issue, _now) do
    source_live?(issue.id) or active_checkout_run?(issue.id)
  end

  defp recovery_source_deferred?(_, _, _), do: false

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

  @doc false
  @spec claim_next_due_case(MapSet.t(binary()) | [binary()], keyword()) ::
          {:ok,
           %{case: RecoveryCase.t(), attempt: RecoveryAttempt.t(), token: String.t()}
           | {:needs_escalation, RecoveryCase.t()}}
          | :none
          | {:error, term()}
  def claim_next_due_case(visited_ids, opts) when is_list(opts) do
    with {:ok, _requested_policy} <- normalize_policy(opts),
         {:ok, visited_ids} <- normalize_visited_ids(visited_ids) do
      now = option_now(opts)
      claimed_by = option_value(opts, :claimed_by) || node() |> to_string()

      result =
        Repo.transaction(fn ->
          query =
            from c in RecoveryCase,
              where:
                ((c.state == "detected" and
                    (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)) or
                   (c.state == "scheduled" and
                      (is_nil(c.next_attempt_at) or c.next_attempt_at <= ^now)) or
                   (c.state == "claimed" and
                      not is_nil(c.lease_expires_at) and c.lease_expires_at <= ^now) or
                   c.state == "exhausted") and c.id not in ^visited_ids,
              order_by: [asc: c.next_attempt_at, asc: c.inserted_at, asc: c.id],
              limit: 1,
              lock: "FOR UPDATE SKIP LOCKED"

          case Repo.one(query) do
            nil ->
              :none

            %RecoveryCase{} = case_row ->
              case claim_locked_case(case_row, opts, now, claimed_by) do
                {:ok, lease} -> {:claimed, lease}
                {:needs_escalation, exhausted_case} -> {:needs_escalation, exhausted_case}
                {:error, reason} -> {:claim_error, case_row.id, reason}
              end
          end
        end)

      case result do
        {:ok, :none} -> :none
        {:ok, {:claimed, lease}} -> {:ok, lease}
        {:ok, {:needs_escalation, case_row}} -> {:ok, {:needs_escalation, case_row}}
        {:ok, {:claim_error, id, reason}} -> {:error, {:case, id, reason}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def claim_next_due_case(_visited_ids, _opts), do: {:error, :invalid_options}

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
            nil -> {:error, :not_found}
            case_row -> claim_locked_case(case_row, opts, now, claimed_by)
          end
        end)

      case result do
        {:ok, {:ok, lease}} ->
          {:ok, lease}

        {:ok, {:needs_escalation, exhausted_case}} ->
          case exhaust_case(exhausted_case, reason: exhausted_case.last_error, now: now) do
            {:ok, %BoardApproval{}} -> {:error, :exhausted}
            {:ok, %RecoveryCase{state: "superseded"}} -> {:error, :superseded}
            {:error, reason} -> {:error, {:exhaustion_failed, reason}}
          end

        {:ok, {:error, reason}} ->
          {:error, reason}

        other ->
          other
      end
    end
  end

  defp claim_locked_case(%RecoveryCase{} = case_row, opts, now, claimed_by) do
    with {:ok, policy} <- policy_for_case(case_row, opts) do
      lease_seconds = policy.lease_seconds

      cond do
        case_row.state == "claimed" and expired?(case_row.lease_expires_at, now) == false ->
          {:error, :already_claimed}

        case_row.state == "claimed" and case_row.attempt_count >= case_row.max_attempts ->
          # A worker died after claiming the final attempt. Close its history
          # and persist exhaustion before handing it to the post-commit
          # escalation path.
          expire_claimed_attempt(case_row, now)

          Repo.update_all(
            from(c in RecoveryCase, where: c.id == ^case_row.id),
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

          {:needs_escalation, Repo.get!(RecoveryCase, case_row.id)}

        case_row.state == "exhausted" ->
          {:needs_escalation, case_row}

        case_row.state not in ["detected", "scheduled", "claimed"] ->
          {:error, :not_claimable}

        (option_value(opts, :due_only) == true and case_row.state == "detected" and
           case_row.next_attempt_at) &&
            DateTime.compare(case_row.next_attempt_at, now) == :gt ->
          {:error, :not_due}

        (case_row.state in ["detected", "scheduled"] and case_row.next_attempt_at) &&
            DateTime.compare(case_row.next_attempt_at, now) == :gt ->
          {:error, :not_due}

        true ->
          if case_row.state == "claimed" and expired?(case_row.lease_expires_at, now) do
            # A lease takeover closes the previous attempt before a new
            # attempt number is claimed.
            expire_claimed_attempt(case_row, now)
          end

          budget_attempt_count = case_row.attempt_count + 1
          attempt_no = next_attempt_no(case_row.id)

          if budget_attempt_count > case_row.max_attempts do
            Repo.update_all(
              from(c in RecoveryCase, where: c.id == ^case_row.id),
              set: [state: "exhausted", exhausted_at: case_row.exhausted_at || now]
            )

            {:needs_escalation, Repo.get!(RecoveryCase, case_row.id)}
          else
            token = Ecto.UUID.generate()
            expires = DateTime.add(now, lease_seconds, :second)

            {1, _} =
              Repo.update_all(
                from(c in RecoveryCase, where: c.id == ^case_row.id),
                set: [
                  state: "claimed",
                  attempt_count: budget_attempt_count,
                  claim_token: token,
                  claimed_at: now,
                  lease_expires_at: expires,
                  claimed_by: claimed_by,
                  last_attempt_at: now
                ]
              )

            attempt =
              %RecoveryAttempt{}
              |> RecoveryAttempt.changeset(%{
                recovery_case_id: case_row.id,
                attempt_no: attempt_no,
                status: "claimed",
                action: "retry",
                source_fingerprint: case_row.source_fingerprint,
                started_at: now,
                node: claimed_by,
                metadata: %{policy: policy.snapshot}
              })
              |> Repo.insert!()

            updated = Repo.get!(RecoveryCase, case_row.id)
            {:ok, %{case: updated, attempt: attempt, token: token}}
          end
      end
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp next_attempt_no(case_id) do
    RecoveryAttempt
    |> where([a], a.recovery_case_id == ^case_id)
    |> select([a], coalesce(max(a.attempt_no), 0))
    |> Repo.one()
    |> Kernel.+(1)
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
    with :ok <- validate_supplied_policy_options(opts),
         now <- option_now(opts),
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

            budget_attempt_count = case_row.attempt_count
            exhausted = budget_attempt_count >= case_row.max_attempts

            {state, next_retry_at} =
              if exhausted,
                do: {"exhausted", nil},
                else:
                  {"scheduled",
                   DateTime.add(now, retry_delay(budget_attempt_count, policy, opts), :second)}

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

  defp release_deferred_claim(lease, opts) do
    with :ok <- validate_supplied_policy_options(opts),
         now <- option_now(opts),
         {:ok, id, token, attempt} <- lease_parts(lease) do
      Repo.transaction(fn ->
        case Repo.one(
               from c in RecoveryCase,
                 where: c.id == ^id and c.claim_token == ^token and c.state == "claimed",
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

            retained_budget_count = max(case_row.attempt_count - 1, 0)

            next_attempt_at =
              DateTime.add(now, retry_delay(retained_budget_count, policy, opts), :second)

            {attempt_count, _} =
              Repo.update_all(
                from(a in RecoveryAttempt,
                  where:
                    a.id == ^attempt.id and a.recovery_case_id == ^id and
                      a.attempt_no == ^attempt.attempt_no and a.status == "claimed"
                ),
                set: [
                  status: "skipped",
                  completed_at: now,
                  error_reason: "recovery_deferred",
                  next_retry_at: next_attempt_at
                ]
              )

            if attempt_count != 1, do: Repo.rollback(:stale_claim)

            {case_count, _} =
              Repo.update_all(
                from(c in RecoveryCase, where: c.id == ^id and c.claim_token == ^token),
                set: [
                  state: "scheduled",
                  attempt_count: retained_budget_count,
                  claim_token: nil,
                  claimed_at: nil,
                  lease_expires_at: nil,
                  claimed_by: nil,
                  next_attempt_at: next_attempt_at
                ]
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
    with {:ok, policy} <- policy_for_source(source, opts),
         source <- source_with_policy(source, policy),
         policy_opts <- put_policy_options(opts, policy),
         {:ok, case_row} <- ensure_source(source),
         {:ok, lease} <- claim_case(case_row, policy_opts) do
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
            {:ok, record_success(lease, policy_opts), value, :recovered}

          {:error, :recovery_deferred} ->
            {:ok, release_deferred_claim(lease, policy_opts), result, :deferred}

          {:error, :superseded} ->
            {:ok, record_superseded(lease, policy_opts), result, :superseded}

          {:error, reason} ->
            failure = record_failure(lease, reason, policy_opts)
            outcome = outcome_for_failure(lease)

            case {failure, outcome} do
              {{:ok, exhausted_case}, :exhausted} ->
                case exhaust_case(exhausted_case, Keyword.put(policy_opts, :reason, reason)) do
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
            {:ok, record_success(lease, policy_opts), value, :recovered}
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
    source = %{source_type: "issue_checkout", issue: issue}

    with {:ok, recovery_opts} <- adapter_recovery_options(opts),
         {:ok, result} <-
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
    with {:ok, _policy} <- normalize_policy(opts),
         :ok <- validate_due_clock(opts) do
      limit = bounded_limit(Keyword.get(opts, :limit, 50))

      process_due_loop(opts, limit, MapSet.new(), empty_due_stats())
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
      errors: [],
      follow_up_cases_created: 0,
      follow_up_attempts: 0
    }
  end

  defp process_due_loop(_opts, 0, _visited_ids, stats), do: stats

  defp process_due_loop(opts, remaining, visited_ids, stats) do
    with {:ok, reservation_now} <- due_time(opts) do
      claim_opts = Keyword.put(opts, :now, reservation_now)

      case claim_next_due_case(visited_ids, claim_opts) do
        :none ->
          stats

        {:ok, %{case: %RecoveryCase{} = case_row} = lease} ->
          stats =
            stats
            |> increment_due_checked()
            |> Map.update!(:claimed, &(&1 + 1))
            |> then(&process_due_lease_safely(lease, claim_opts, opts, &1))

          process_due_loop(
            opts,
            remaining - 1,
            MapSet.put(visited_ids, case_row.id),
            stats
          )

        {:ok, {:needs_escalation, %RecoveryCase{} = case_row}} ->
          stats =
            stats
            |> increment_due_checked()
            |> process_due_escalation_safely(case_row, opts)

          process_due_loop(
            opts,
            remaining - 1,
            MapSet.put(visited_ids, case_row.id),
            stats
          )

        {:error, {:case, id, reason}} ->
          stats =
            stats
            |> increment_due_checked()
            |> Map.update!(:failed, &(&1 + 1))
            |> Map.update!(:errors, &[reason | &1])

          process_due_loop(opts, remaining - 1, MapSet.put(visited_ids, id), stats)

        {:error, reason} ->
          stats
          |> Map.put(:error, :database_unavailable)
          |> Map.update!(:errors, &[reason | &1])
      end
    else
      {:error, reason} ->
        stats
        |> Map.put(:error, reason)
        |> Map.update!(:errors, &[reason | &1])
    end
  end

  defp increment_due_checked(stats) do
    %{stats | checked: stats.checked + 1, due: stats.due + 1}
  end

  defp process_due_escalation_safely(stats, %RecoveryCase{} = case_row, opts) do
    with {:ok, escalation_now} <- due_time(opts) do
      result =
        protected_call(fn ->
          exhaust_case(case_row, reason: case_row.last_error, now: escalation_now)
        end)

      case result do
        {:ok, {:ok, %BoardApproval{}}} ->
          %{stats | exhausted: stats.exhausted + 1}

        {:ok, {:ok, %RecoveryCase{state: "superseded"}}} ->
          %{stats | superseded: stats.superseded + 1}

        {:ok, {:error, reason}} ->
          %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}

        {:caught, reason} ->
          %{stats | failed: stats.failed + 1, errors: [bounded_error(reason) | stats.errors]}
      end
    else
      {:error, reason} ->
        %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp process_due_lease_safely(lease, callback_opts, opts, stats) do
    callback_result =
      case protected_call(fn -> process_due_callback(lease, callback_opts) end) do
        {:ok, result} -> result
        {:caught, reason} -> {:error, reason}
      end

    with {:ok, completion_now} <- due_time(opts) do
      completion_opts = Keyword.put(opts, :now, completion_now)

      case protected_call(fn ->
             finish_due_result(lease, callback_result, completion_opts, stats)
           end) do
        {:ok, updated_stats} ->
          updated_stats

        {:caught, reason} ->
          %{stats | failed: stats.failed + 1, errors: [bounded_error(reason) | stats.errors]}
      end
    else
      {:error, reason} ->
        %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp process_due_callback(
         %{case: %RecoveryCase{source_type: "heartbeat_run"} = case_row},
         opts
       ) do
    case {Repo.get(Run, case_row.source_run_id), Repo.get(Issue, case_row.issue_id)} do
      {%Run{} = run, %Issue{} = issue} ->
        cond do
          current_source_matches?(case_row, run, issue) and source_live?(issue.id) ->
            {:error, :recovery_deferred}

          current_source_matches?(case_row, run, issue) ->
            kind =
              if case_row.source_status in ["pending", "queued"], do: :orphaned, else: :stale

            case HeartbeatEngine.recover_run_if_current(
                   run,
                   run_source_guard(case_row, kind),
                   kind,
                   now: option_now(opts)
                 ) do
              {:ok, recovered} -> {:ok, run_recovery_result(recovered, opts)}
              error -> error
            end

          terminal_case_run?(case_row, run, issue) ->
            {:error, {:terminal_run, run}}

          true ->
            {:error, :superseded}
        end

      _ ->
        {:error, :superseded}
    end
  end

  defp process_due_callback(
         %{case: %RecoveryCase{source_type: "issue_checkout"} = case_row},
         _opts
       ) do
    case Repo.get(Issue, case_row.issue_id) do
      %Issue{status: status} = issue
      when status in [:todo, "todo"] and not is_nil(case_row.parent_case_id) ->
        # Approved retry children are durable markers for the dispatcher
        # wake. Once the issue is reopened, consume the marker without
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
  end

  defp finish_due_result(
         lease,
         {:ok, %{run: %Run{}, follow_up: follow_up}},
         opts,
         stats
       ) do
    stats = add_follow_up_stats(stats, follow_up)

    case record_success(lease, opts) do
      {:ok, _case} ->
        %{stats | processed: stats.processed + 1, recovered: stats.recovered + 1}

      {:error, reason} ->
        %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp finish_due_result(lease, {:error, {:terminal_run, %Run{} = run}}, opts, stats) do
    follow_up = protected_checkout_follow_up(run, opts)
    stats = add_follow_up_stats(stats, follow_up)

    case record_superseded(lease, opts) do
      {:ok, _case} -> %{stats | processed: stats.processed + 1, superseded: stats.superseded + 1}
      {:error, reason} -> %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
  end

  defp finish_due_result(lease, {:error, :recovery_deferred}, opts, stats) do
    case release_deferred_claim(lease, opts) do
      {:ok, _case} -> %{stats | processed: stats.processed + 1, scheduled: stats.scheduled + 1}
      {:error, reason} -> %{stats | failed: stats.failed + 1, errors: [reason | stats.errors]}
    end
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
    source = %{source_type: "heartbeat_run", issue: nil, run: run}

    with {:ok, recovery_opts} <- adapter_recovery_options(opts),
         {:ok, issue} <- Issues.get_issue(run.issue_id) do
      if run_scope_matches?(run, issue) and
           HeartbeatEngine.recovery_deferred?(run, option_now(opts)) do
        {:ok,
         %{
           run: run,
           outcome: :deferred,
           case: nil,
           recovery: empty_follow_up(:deferred)
         }}
      else
        recover_run_with_attempt(source, issue, kind, run, recovery_opts, opts)
      end
    end
  end

  defp recover_run_with_attempt(source, issue, kind, run, recovery_opts, opts) do
    with {:ok, result} <-
           with_attempt(
             %{source | issue: issue},
             recovery_opts,
             fn lease ->
               current = Repo.get(Run, run.id)

               with %Run{} = current <- current,
                    {:ok, current_issue} <- Issues.get_issue(current.issue_id),
                    true <- current_source_matches?(lease.case, current, current_issue) do
                 if source_live?(current.issue_id) do
                   {:error, :recovery_deferred}
                 else
                   effective_kind = effective_run_recovery_kind(kind, current.status)

                   case HeartbeatEngine.recover_run_if_current(
                          current,
                          run_source_guard(lease.case, effective_kind),
                          effective_kind,
                          now: option_now(opts)
                        ) do
                     {:error, {:invalid_status, _status}} -> {:error, :superseded}
                     {:ok, updated} -> {:ok, run_recovery_result(updated, opts)}
                     {:error, reason} -> {:error, reason}
                   end
                 end
               else
                 _ -> {:error, :superseded}
               end
             end
           ) do
      recovered_run = run_result(result.result, run)

      follow_up =
        case result do
          %{result: %{follow_up: follow_up}} ->
            follow_up

          %{outcome: :superseded} ->
            terminal_checkout_follow_up(run, opts)

          _ ->
            empty_follow_up(result.outcome)
        end

      {:ok,
       %{
         run: recovered_run,
         outcome: result.outcome,
         case: result.case,
         recovery: follow_up
       }}
    end
  end

  defp current_source_matches?(
         %RecoveryCase{source_type: "heartbeat_run"} = case_row,
         %Run{} = run,
         %Issue{} = issue
       ) do
    {current_fp, snapshot} = Fingerprint.for_run(run, issue)

    exact_v2_snapshot?(case_row, snapshot, heartbeat_snapshot_keys()) and
      case_row.company_id == issue.company_id and case_row.company_id == run.company_id and
      case_row.issue_id == issue.id and case_row.issue_id == run.issue_id and
      case_row.source_id == run.id and case_row.source_run_id == run.id and
      case_row.agent_id == run.agent_id and case_row.source_status == to_string(run.status) and
      to_string(run.status) not in @terminal_run_statuses and
      case_row.source_fingerprint == current_fp
  end

  defp current_source_matches?(
         %RecoveryCase{source_type: "issue_checkout"} = case_row,
         %Issue{} = issue,
         _optional_issue
       ) do
    {current_fp, snapshot} = Fingerprint.for_issue_checkout(issue)

    exact_v2_snapshot?(case_row, snapshot, issue_checkout_snapshot_keys()) and
      case_row.company_id == issue.company_id and case_row.issue_id == issue.id and
      case_row.source_id == issue.id and case_row.agent_id == issue.assignee_id and
      case_row.source_run_id == issue.checkout_run_id and
      case_row.source_status == to_string(issue.status) and
      issue.status in [:in_progress, "in_progress"] and
      case_row.source_fingerprint == current_fp
  end

  defp current_source_matches?(_, _, _), do: false

  defp exact_v2_snapshot?(%RecoveryCase{} = case_row, current_snapshot, keys) do
    persisted = case_row.source_snapshot

    is_map(persisted) and case_row.fingerprint_version == Fingerprint.version() and
      map_size(persisted) == length(keys) and
      Enum.all?(keys, fn key ->
        Map.has_key?(persisted, key) and Map.get(persisted, key) == Map.get(current_snapshot, key)
      end)
  end

  defp effective_run_recovery_kind(:orphaned, "running"), do: :stale
  defp effective_run_recovery_kind(kind, _status), do: kind

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

  defp run_result(%{run: %Run{} = run}, _fallback), do: run
  defp run_result(%Run{} = run, _fallback), do: run
  defp run_result(_, fallback), do: fallback

  @doc false
  @spec recover_unbound_checkout_after_run(Run.t(), keyword()) ::
          :ok | {:error, term()}
  def recover_unbound_checkout_after_run(%Run{} = run, opts) when is_list(opts) do
    case recover_unbound_checkout_after_run_detailed(run, opts) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def recover_unbound_checkout_after_run(_run, _opts), do: {:error, :invalid_run_source}

  defp recover_unbound_checkout_after_run_detailed(%Run{} = run, opts) do
    current_run = Repo.get(Run, run.id)

    cond do
      not matching_terminal_run?(current_run, run) ->
        {:ok, empty_follow_up(:not_terminal)}

      source_live?(run.issue_id) or active_checkout_run?(run.issue_id) ->
        {:ok, empty_follow_up(:deferred)}

      true ->
        case Issues.get_issue(run.issue_id) do
          {:ok, %Issue{status: status, checkout_run_id: nil} = issue}
          when status in [:in_progress, "in_progress"] ->
            previous = active_checkout_case(issue.id)

            case recover_orphaned_issue(issue, opts) do
              {:ok, %{outcome: outcome, case: recovery_case}} ->
                {:ok, follow_up_metadata(previous, recovery_case, outcome)}

              {:error, reason} ->
                {:error, reason}
            end

          _ ->
            {:ok, empty_follow_up(:not_applicable)}
        end
    end
  rescue
    error -> {:error, error}
  end

  defp matching_terminal_run?(%Run{} = current, %Run{} = recovered) do
    current.id == recovered.id and current.company_id == recovered.company_id and
      current.issue_id == recovered.issue_id and current.agent_id == recovered.agent_id and
      to_string(current.status) in @terminal_run_statuses and current.status == recovered.status
  end

  defp matching_terminal_run?(_, _), do: false

  defp run_recovery_result(%Run{} = run, opts) do
    %{run: run, follow_up: protected_checkout_follow_up(run, opts)}
  end

  defp protected_checkout_follow_up(%Run{} = run, opts) do
    case recover_unbound_checkout_after_run_detailed(run, opts) do
      {:ok, metadata} ->
        metadata

      {:error, reason} ->
        Logger.warning("Recovery left an unbound checkout for a later durable attempt",
          component: "recovery",
          run_id: run.id,
          issue_id: run.issue_id,
          error: bounded_error(reason)
        )

        empty_follow_up(:failed)
    end
  rescue
    error ->
      Logger.warning("Recovery checkout follow-up raised",
        component: "recovery",
        run_id: run.id,
        issue_id: run.issue_id,
        error: bounded_error(error)
      )

      empty_follow_up(:failed)
  end

  defp terminal_checkout_follow_up(%Run{} = source_run, opts) do
    case Repo.get(Run, source_run.id) do
      %Run{} = current when current.status in @terminal_run_statuses ->
        if current.company_id == source_run.company_id and current.issue_id == source_run.issue_id and
             current.agent_id == source_run.agent_id do
          protected_checkout_follow_up(current, opts)
        else
          empty_follow_up(:superseded)
        end

      _ ->
        empty_follow_up(:superseded)
    end
  end

  defp active_checkout_case(issue_id) do
    Repo.one(
      from c in RecoveryCase,
        where:
          c.source_type == "issue_checkout" and c.source_id == ^issue_id and
            c.state in ^RecoveryCase.active_states(),
        order_by: [desc: c.inserted_at],
        limit: 1,
        select: %{id: c.id, attempt_count: c.attempt_count}
    )
  end

  defp follow_up_metadata(previous, %RecoveryCase{} = recovery_case, outcome) do
    previous_attempts =
      if previous && previous.id == recovery_case.id, do: previous.attempt_count, else: 0

    %{
      cases_created: if(previous && previous.id == recovery_case.id, do: 0, else: 1),
      attempts: max(recovery_case.attempt_count - previous_attempts, 0),
      outcome: outcome
    }
  end

  defp empty_follow_up(outcome), do: %{cases_created: 0, attempts: 0, outcome: outcome}

  defp add_follow_up_stats(stats, %{cases_created: cases, attempts: attempts}) do
    %{
      stats
      | follow_up_cases_created: stats.follow_up_cases_created + cases,
        follow_up_attempts: stats.follow_up_attempts + attempts
    }
  end

  defp add_follow_up_stats(stats, _metadata), do: stats

  defp terminal_case_run?(%RecoveryCase{} = case_row, %Run{} = run, %Issue{} = issue) do
    case_row.source_type == "heartbeat_run" and case_row.company_id == issue.company_id and
      case_row.company_id == run.company_id and case_row.issue_id == issue.id and
      case_row.issue_id == run.issue_id and case_row.source_id == run.id and
      case_row.source_run_id == run.id and case_row.agent_id == run.agent_id and
      run.status in @terminal_run_statuses
  end

  defp run_scope_matches?(%Run{} = run, %Issue{} = issue) do
    is_binary(run.company_id) and run.company_id == issue.company_id and run.issue_id == issue.id
  end

  defp run_scope_matches?(_, _), do: false

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
         case: %RecoveryCase{attempt_count: count, max_attempts: max}
       })
       when count >= max, do: :exhausted

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
          active && active.source_fingerprint == attrs.source_fingerprint &&
              case_policy_matches?(active, attrs) ->
            active

          active && active.source_fingerprint == attrs.source_fingerprint ->
            Repo.rollback(:invalid_policy)

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
            if row.source_fingerprint == attrs.source_fingerprint &&
                 case_policy_matches?(row, attrs) do
              {:ok, row}
            else
              if row.source_fingerprint == attrs.source_fingerprint,
                do: {:error, :invalid_policy},
                else: do_ensure_case(attrs, attempt + 1)
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
              %RecoveryCase{} = row ->
                if case_policy_matches?(row, attrs),
                  do: {:ok, row},
                  else: {:error, :invalid_policy}

              _ ->
                do_ensure_case(attrs, attempt + 1)
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

  defp expire_claimed_attempt(%RecoveryCase{id: case_id}, now) do
    # The case-row lock admits only one current claim. Audit ordinals remain
    # monotonic even when a deferred claim returned its retry-budget slot, so
    # close the sole claimed row rather than deriving its ordinal from the
    # budget counter.
    Repo.update_all(
      from(a in RecoveryAttempt,
        where: a.recovery_case_id == ^case_id and a.status == "claimed"
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

  defp adapter_recovery_options(opts) when is_list(opts) do
    outer = Keyword.delete(opts, :recovery_opts)

    nested =
      case Keyword.get_values(opts, :recovery_opts) do
        [] -> []
        [value] when is_list(value) -> value
        # Multiple nested containers have no unambiguous precedence, even
        # when their current values happen to match.
        [_ | _] -> :invalid
      end

    cond do
      nested == :invalid ->
        {:error, :invalid_policy}

      not duplicate_policy_values_valid?(outer) or not duplicate_policy_values_valid?(nested) ->
        {:error, :invalid_policy}

      Enum.any?(@policy_option_keys, fn key ->
        outer_values = Keyword.get_values(outer, key)
        nested_values = Keyword.get_values(nested, key)

        outer_values != [] and nested_values != [] and
            not (List.first(outer_values) === List.first(nested_values))
      end) ->
        {:error, :invalid_policy}

      true ->
        merged = Keyword.merge(outer, nested)

        case normalize_policy(merged) do
          {:ok, _policy} -> {:ok, merged}
          {:error, :invalid_policy} = error -> error
        end
    end
  end

  defp adapter_recovery_options(_opts), do: {:error, :invalid_policy}

  defp source_with_policy(%RecoveryCase{} = source, _policy), do: source

  defp source_with_policy(source, policy) when is_map(source) do
    Map.merge(source, %{
      max_attempts: policy.max_attempts,
      base_delay: policy.base_delay,
      max_delay: policy.max_delay,
      lease_seconds: policy.lease_seconds
    })
  end

  defp put_policy_options(opts, policy) when is_list(opts) do
    Enum.reduce(@policy_option_keys, opts, fn key, acc ->
      Keyword.put(acc, key, Map.fetch!(policy, key))
    end)
  end

  defp policy_for_source(%RecoveryCase{} = source, opts), do: policy_for_case(source, opts)
  defp policy_for_source(source, opts) when is_map(source), do: normalize_policy(opts)
  defp policy_for_source(_source, _opts), do: {:error, :invalid_policy}

  defp normalize_policy(opts) when is_list(opts) do
    with {:ok, max_attempts} <-
           duplicate_safe_value(
             Keyword.get_values(opts, :max_attempts),
             :max_attempts,
             @max_policy_attempts
           ),
         {:ok, base_delay} <-
           duplicate_safe_value(Keyword.get_values(opts, :base_delay), :base_delay, 60),
         {:ok, max_delay} <-
           duplicate_safe_value(
             Keyword.get_values(opts, :max_delay),
             :max_delay,
             @max_policy_delay_seconds
           ),
         {:ok, lease_seconds} <-
           duplicate_safe_value(
             Keyword.get_values(opts, :lease_seconds),
             :lease_seconds,
             @lease_seconds
           ) do
      normalize_policy_values(max_attempts, base_delay, max_delay, lease_seconds)
    end
  end

  defp normalize_policy(opts) when is_map(opts) do
    with {:ok, max_attempts} <-
           map_policy_value(opts, :max_attempts, "max_attempts", @max_policy_attempts),
         {:ok, base_delay} <- map_policy_value(opts, :base_delay, "base_delay", 60),
         {:ok, max_delay} <-
           map_policy_value(opts, :max_delay, "max_delay", @max_policy_delay_seconds),
         {:ok, lease_seconds} <-
           map_policy_value(opts, :lease_seconds, "lease_seconds", @lease_seconds) do
      normalize_policy_values(max_attempts, base_delay, max_delay, lease_seconds)
    end
  end

  defp normalize_policy(_), do: {:error, :invalid_policy}

  defp normalize_policy_values(max_attempts, base_delay, max_delay, lease_seconds) do
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

  defp duplicate_policy_values_valid?(opts) do
    Enum.all?(@policy_option_keys, fn key ->
      case duplicate_safe_value(Keyword.get_values(opts, key), key, nil) do
        {:ok, _value} -> true
        {:error, :invalid_policy} -> false
      end
    end)
  end

  defp map_policy_value(opts, atom_key, string_key, default) do
    values =
      [atom_key, string_key]
      |> Enum.filter(&Map.has_key?(opts, &1))
      |> Enum.map(&Map.fetch!(opts, &1))

    duplicate_safe_value(values, atom_key, default)
  end

  defp duplicate_safe_value([], _key, default), do: {:ok, default}

  defp duplicate_safe_value([value | rest] = values, key, _default) do
    if Enum.all?(values, &valid_policy_option_value?(key, &1)) and
         Enum.all?(rest, &(&1 === value)),
       do: {:ok, value},
       else: {:error, :invalid_policy}
  end

  defp valid_policy_option_value?(:max_attempts, value),
    do: is_integer(value) and value > 0 and value <= @max_policy_attempts

  defp valid_policy_option_value?(key, value) when key in [:base_delay, :max_delay],
    do: is_integer(value) and value > 0 and value <= @max_policy_delay_seconds

  defp valid_policy_option_value?(:lease_seconds, value),
    do: is_integer(value) and value > 0 and value <= @max_policy_lease_seconds

  defp validate_supplied_policy_options(opts) when is_list(opts) or is_map(opts) do
    if Enum.all?(@policy_option_keys, fn key ->
         case duplicate_safe_value(supplied_policy_values(opts, key), key, :absent) do
           {:ok, _value} -> true
           {:error, :invalid_policy} -> false
         end
       end),
       do: :ok,
       else: {:error, :invalid_policy}
  end

  defp validate_supplied_policy_options(_opts), do: {:error, :invalid_policy}

  defp supplied_policy_values(opts, key) when is_list(opts), do: Keyword.get_values(opts, key)

  defp supplied_policy_values(opts, key) when is_map(opts) do
    [key, Atom.to_string(key)]
    |> Enum.filter(&Map.has_key?(opts, &1))
    |> Enum.map(&Map.fetch!(opts, &1))
  end

  # A case snapshots its effective policy at detection time. Later calls may
  # omit policy values or repeat the persisted values, but cannot replace them.
  defp policy_for_case(%RecoveryCase{} = case_row, opts) do
    snapshot = normalize_policy_snapshot(case_row.policy_snapshot)

    with :ok <- validate_supplied_policy_options(opts),
         true <- map_size(snapshot) == length(@policy_option_keys),
         {:ok, policy} <- normalize_policy(snapshot),
         true <- policy.max_attempts === case_row.max_attempts,
         true <-
           Enum.all?(@policy_option_keys, fn key ->
             is_nil(option_value(opts, key)) or
               option_value(opts, key) === Map.fetch!(policy, key)
           end) do
      {:ok, policy}
    else
      _ -> {:error, :invalid_policy}
    end
  end

  defp case_policy_matches?(%RecoveryCase{} = case_row, attrs) do
    case policy_for_case(case_row, Map.get(attrs, :policy_snapshot, %{})) do
      {:ok, persisted} -> persisted.snapshot === attrs.policy_snapshot
      {:error, :invalid_policy} -> false
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

  defp bounded_limit(value) when is_integer(value) and value > 0, do: min(value, 100)
  defp bounded_limit(_), do: 50

  defp normalize_visited_ids(%MapSet{} = visited_ids) do
    normalize_visited_ids(MapSet.to_list(visited_ids))
  end

  defp normalize_visited_ids(visited_ids) when is_list(visited_ids) do
    if Enum.all?(visited_ids, &(is_binary(&1) and &1 != "")),
      do: {:ok, Enum.uniq(visited_ids)},
      else: {:error, :invalid_options}
  end

  defp normalize_visited_ids(_), do: {:error, :invalid_options}

  defp bounded_attempt_history(case_id) do
    Repo.all(
      from a in RecoveryAttempt,
        where: a.recovery_case_id == ^case_id,
        order_by: [desc: a.attempt_no],
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
    |> Enum.reverse()
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

  defp validate_due_clock(opts) do
    case Keyword.get(opts, :clock) do
      nil -> :ok
      clock when is_function(clock, 0) -> :ok
      _ -> {:error, :invalid_clock}
    end
  end

  defp due_time(opts) do
    case Keyword.fetch(opts, :now) do
      {:ok, %DateTime{} = now} ->
        {:ok, now}

      {:ok, _invalid} ->
        {:error, :invalid_clock}

      :error ->
        case Keyword.get(opts, :clock) do
          nil ->
            {:ok, DateTime.utc_now() |> DateTime.truncate(:second)}

          clock when is_function(clock, 0) ->
            case protected_call(clock) do
              {:ok, %DateTime{} = now} -> {:ok, DateTime.truncate(now, :second)}
              _ -> {:error, :invalid_clock}
            end

          _ ->
            {:error, :invalid_clock}
        end
    end
  end

  defp protected_call(callback) do
    try do
      {:ok, callback.()}
    rescue
      exception -> {:caught, {:exception, exception}}
    catch
      kind, reason -> {:caught, {kind, reason}}
    end
  end

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
