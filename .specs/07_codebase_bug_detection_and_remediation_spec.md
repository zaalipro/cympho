# Spec 07: Codebase Bug Detection and Remediation (verified revision)

> **Revision note.** The first draft claimed 68 defects across 7 domains and proposed 51 tasks
> touching ~95 files. Every claim has now been checked against the code. **30 are confirmed**
> with file:line evidence, **16 are rejected** (already fixed, factually wrong, or unreachable),
> and the rest were speculative hardening with no demonstrated failure.
>
> Deleted from the draft: the architecture diagrams, the two mermaid flows, the 60-entry
> "Components and Interfaces" catalogue (a substantial fraction of its signatures do not match
> the code), and the 95-file change list. A single 95-file tranche is unreviewable and
> contradicts the repo's "surgical changes" rule.
>
> Everything below is either evidenced or explicitly marked unverified.

---

# Verification summary

| Bucket | Count | Meaning |
|---|---|---|
| Confirmed | 30 | Reproduced by reading the code; file:line cited |
| Rejected | 16 | Already fixed, factually wrong, or unreachable — see "Rejected claims" |
| Deferred | 2 | Real, but the fix needs a design decision first |
| Unverified | 16 | Original criteria not checked; not scheduled |

Three confirmed defects make an entire subsystem non-functional (Requirement A). None are caught
by the existing 3,837-test suite, because none of those paths have any coverage.

---

# Requirements

## Requirement A: Dead subsystems

**User Story:** As an operator, I want adapter health monitoring, WebSocket event replay, and
document diffs to actually function, so that failures are detected, reconnects catch up, and
revision comparison returns a result instead of a 500.

### Acceptance Criteria

**A.1 — Adapter health failures are counted.** All eight adapters return `%{status: :unhealthy}`
on failure, but `HealthChecker` declares `@type health_state :: :healthy | :degraded | :unavailable`
(`health_checker.ex:22`) and `process_health_result/3` only treats
`new_health_status in [:degraded, :unavailable]` as a failure (`health_checker.ex:280`).
`:unhealthy` falls through to the `true ->` no-op branch (`health_checker.ex:311`), so
`consecutive_failures` never increments, no agent ever reaches `status: :error`, the recovery
branch is unreachable (`last_health_status` never leaves `:healthy`), and
`health_status_changed` is never broadcast. WHEN an adapter reports `:unhealthy` or `:unknown`
THEN `HealthChecker` SHALL normalise it to `:unavailable` and follow the existing failure path.

**A.2 — Event replay survives a purge tick.** `drop_old_ids/2` reduces over a reversed list while
prepending, so `kept_rev` is already newest-first — then it is reversed again on return
(`event_store.ex:246`). Every 60-second `:purge_tick` flips a topic's index to ascending.
`fetch_since/3` then reads `min_id = List.last(ids)` (`event_store.ex:123`) as the oldest id when
it is now the newest, so nearly every valid watermark yields `{:error, :replay_window_expired}`
and the client is pushed `"replay_expired"` (`company_channel.ex:120`). `fetch_latest` returns
the oldest slice for the same reason. WHEN `purge_old/1` runs THEN the retained id list SHALL
stay newest-first and `fetch_since/3` SHALL return events chronologically.

**A.3 — Document diffs return a result.** Three stacked defects:
(a) `compute_line_diff/3` destructures a 3-tuple from `diff_lines/4`, which returns a 4-tuple
(`documents.ex:270` vs `:277`, `:282`, `:287`) — a guaranteed `MatchError` on every call;
(b) even with the arity fixed, `find_common_sequence/4` returns `Enum.reverse(new_prefix)` as its
third element (`documents.ex:313`), so the caller binds `new_remainder` to `[new_head]` and
discards `new_rest` entirely (`documents.ex:300-307`) — every new line after the first divergence
is dropped; (c) `DocumentController.diff/2` renders assign `diff:` (`document_controller.ex:70`)
while `DocumentJSON.diff/1` matches `%{result: result}` reading `.base` / `.target`
(`document_json.ex:18-25`) and `get_diff/2` returns `%{current:, other:, diff:}`
(`documents.ex:252`) — three mismatched shapes.
Reachable via `router.ex:280`; zero test coverage. WHEN two revisions are compared THEN a
well-formed diff SHALL be returned over both the API and the context function.

---

## Requirement B: Security and tenant isolation

**User Story:** As an enterprise tenant, I want redirects, webhook verification, broadcasts,
capability assignment, and database constraints to hold the company boundary.

### Acceptance Criteria

**B.1 — No open redirect.** `is_safe_path?/1` requires only `String.starts_with?(path, "/")`
(`company_switcher_controller.ex:63`), which `//evil.com` satisfies; browsers treat it as
protocol-relative. WHEN `return_to` begins with `//` or `/\` THEN the controller SHALL fall back
to a safe path.

**B.2 — Chunked webhook bodies verify.** `CacheBodyReader.read_body/2` hard-matches
`{:ok, body, conn}` (`cache_body_reader.ex:13`); `Plug.Conn.read_body/2` returns
`{:more, partial, conn}` past `:read_length` (1 MB default), raising `MatchError` inside
`Plug.Parsers` — before `GithubController.verify_signature/2` (`github_controller.ex:239`) ever
runs. WHEN a payload arrives in chunks THEN the reader SHALL accumulate them and HMAC
verification SHALL succeed.

**B.3 — Governance broadcasts are company-scoped.** `principal_permissions.ex:92` and `:159`
broadcast on the global topic `"principal_permissions"`; `governance_audit_logs.ex:106` on
`"governance_audit"`, with matching global `subscribe/0` at `principal_permissions.ex:269` and
`governance_audit_logs.ex:121`. This contradicts the CLAUDE.md scoping rule. Currently **latent**
— no caller of either `subscribe/0` exists — which is why it must be fixed now: the first
LiveView to subscribe leaks silently. WHEN a grant or audit event is created THEN it SHALL
broadcast only to `company:#{company_id}:*`, dropping `nil`/blank `company_id`.

**B.4 — Skill assignment is tenant-checked.** `Skills.assign_skill_to_agent/3` (`skills.ex:585`)
validates nothing but the changeset. Its only caller is
`handle_event("toggle_skill", %{"plugin_id" => plugin_id}, socket)` (`agent_live/show.ex:512`),
and LiveView event params are client-controlled — a crafted event assigns any company's plugin to
the caller's agent. WHEN `agent.company_id != plugin.company_id` THEN the call SHALL return
`{:error, :company_mismatch}`.

**B.5 — Unique indexes are company-scoped.** Four global indexes collide across tenants:
`labels [:name]` (`027_create_labels.exs:12`), `projects [:prefix]`
(`014_add_unique_index_to_projects_prefix.exs:6`), `tool_call_traces [:content_hash]`
(`20260427000015_create_tool_call_traces.exs:41`), and
`decisions [:decision_key, :parent_decision_id]` (`20260425181500_create_decision_tracking.exs:38`).
WHEN two companies use the same label name, project prefix, or decision key THEN both SHALL
succeed.

Two corrections to the draft's proposed fix:
- The decisions index is partial (`where: status = 'active'`) and Postgres treats NULLs as
  distinct, so today it constrains **only** rows with a non-null `parent_decision_id`. Top-level
  decision keys are already unconstrained. Scope by company and preserve that semantics; do not
  add a NULL-partial index without first deciding whether root decision keys should be unique.
- `[:company_id, :content_hash]` is **not sufficient** for tool call traces.
  `calculate_content_hash/1` (`tool_call_trace.ex:102-113`) excludes `agent_id`, `run_id` and
  `company_id`, and `occurred_at` is `:utc_datetime` (1-second resolution), so one company making
  the same call twice in a second still collides. **Drop the unique index entirely** — uniqueness
  was never the point; `chain_hash` carries the tamper evidence.

---

## Requirement C: Authentication and account lifecycle

**User Story:** As a new user or administrator, I want registration, login, company bootstrap,
and invites to work regardless of email casing or membership state.

### Acceptance Criteria

**C.1 — Emails normalise.** `validate_email/1` (`user.ex:83-86`) checks format and length only;
nothing downcases. `Authentication.authenticate_user/2` matches exactly
(`authentication.ex:108`). Registering `Alice@Example.Com` and logging in as
`alice@example.com` fails, and `unique_constraint(:email)` admits both as separate accounts.
WHEN a user registers or authenticates THEN the email SHALL be trimmed and downcased.

**C.2 — API-provisioned users can log in.** `Users.create_user/1` (`users.ex:86`) uses
`User.changeset/2`, which casts `:email`, `:name` and notification fields but **not `:password`**
(`user.ex:30-38`; `:password` appears only in `registration_changeset/2` at `:49`). The submitted
password is silently dropped and no hash is written. `UserController.create/2`
(`user_controller.ex:26-32`) then inserts user and membership as two unguarded statements.
WHEN `POST /api/users` includes a password THEN it SHALL be hashed, and user + membership SHALL
be inserted in one `Ecto.Multi`.

**C.3 — A new user can create their first company.** `UserAuth.call/2` exempts zero-membership
users only for `:accept_invite` (`user_auth.ex:33`, `:58`); everything else falls to
`{:error, :no_companies}` → 401 (`user_auth.ex:48`). `POST /api/companies` (`router.ex:293`) and
`POST /api/companies/import` (`router.ex:312`) sit behind that plug. WHEN an authenticated user
with zero memberships calls either THEN the request SHALL be permitted.

**C.4 — Join requests are reachable.** `:create_join_request` is in the `CompanyAccess` plug's
action list (`company_controller.ex:9-17`), and that plug 404s any caller failing
`Companies.has_access?/2` (`company_access.ex:32`). A join request is by definition from a
non-member, so `router.ex:301` can never succeed. WHEN a non-member submits a join request THEN
the plug SHALL NOT halt it.

**C.5 — Accepting an invite twice is not an error.** `accept_invite/2` calls
`create_membership!/1` (`companies.ex:2927`), which raises `Ecto.InvalidChangesetError` on the
membership unique constraint. WHEN the user is already a member THEN the call SHALL resolve
cleanly.

---

## Requirement D: Correctness and robustness

**User Story:** As an operator, I want background workers, governance execution, and real-time
views to degrade gracefully instead of aborting whole operations.

### Acceptance Criteria

**D.1 — One bad notification preference does not kill the rest.** `dispatch_to_user/2` calls
`String.to_existing_atom(pref.channel_type)` then `Map.fetch!(@channels, type)`
(`dispatcher.ex:98-99`) — outside the supervised task, inside `Enum.map`. An unrecognised type
raises `ArgumentError` or `KeyError` and aborts the entire dispatch, so the user receives nothing
on any channel. Unknown channels SHALL be skipped with a debug log.

**D.2 — A refused transition does not abort project cancellation.**
`Decisions.Executor.cancel_project/2` hard-matches `{:ok, _} = Issues.transition_issue(...)`
inside `Enum.each` (`executor.ex:107`). One issue the state machine refuses raises `MatchError`,
leaving the remaining issues open **and** the project unarchived — a half-executed decision.
It SHALL log a warning, continue, and still archive.

**D.3 — Swarm launch is atomic.** `Swarm.do_launch/2` (`swarm.ex:168`) provisions temporary
agents, worker issues, the CTO issue, blockers and state updates with no transaction; a mid-way
failure orphans agents and issues. It SHALL run inside one `Repo.transaction`.

**D.4 — Descendant trees are pre-order.** `walk_descendants/4` builds `[node | subtree ++ acc]`
(`issues.ex:289`) and the caller reverses the whole list (`issues.ex:260`), so children render
before their parent and subtrees come out reversed. It SHALL return depth-first pre-order.

**D.5 — Read-state tracking survives deletions and orders correctly.**
`Enum.drop_while(...) |> tl()` (`issue_read_states.ex:70`) raises `ArgumentError` when the
last-read comment was deleted (`drop_while` returns `[]`). Separately,
`where: rs.last_read_comment_id < ^comment_id` (`:220`) compares UUIDs lexicographically as a
stand-in for "before", which is meaningless for v4 UUIDs — unread targeting is effectively
random. Both SHALL be fixed: fall back safely, and compare timestamps.

**D.6 — Negative budget limits are rejected.** `validate_amounts/1` runs only `if limit && spent`
(`budget.ex:114`); on create `spent_amount` is not in `get_change`, so a negative
`limit_amount` passes. The limit SHALL be validated independently of `spent`.

**D.7 — Comments on project-less issues broadcast.** `Events.broadcast_comment/2` requires both
`company_id` **and** `project_id` non-blank (`events.ex:63-65`); any issue with
`project_id == nil` silently hits `_ -> :ok`. It SHALL broadcast to
`company:#{company_id}:comments` when there is no project.

**D.8 — Subtopic joins keep the replay watermark.** `dispatch_sub_topic/4` passes a literal `%{}`
to every delegate channel (`company_channel.ex:129`, `:133`, `:137`, `:141`), discarding
`last_event_id`, so replay works only on the bare `company:<id>` topic. It SHALL forward the
join payload.

**D.9 — Runs without an issue are billed.** `record_usage_event/1` opens with
`with {:ok, %Issue{} = issue} <- Issues.get_issue(run.issue_id)` and has no `else`
(`heartbeat_engine.ex:715`), so a run whose issue is nil or deleted silently skips
`Finances.record_token_usage/1` despite real spend. It SHALL fall back to `run.company_id`.

**D.10 — Filtered Kanban ignores other projects.** `handle_info({:issue_created, issue}, socket)`
prepends unconditionally (`kanban_live/index.ex:181`) without consulting `selected_project_id`.

**D.11 — Inbox unsubscribes on "all".** `maybe_subscribe_to_agent/1` guards on
`agent_id != "all"` (`inbox_live/index.ex:1081`), so selecting "all" takes the else branch,
leaving the previous subscription live and `subscribed_agent_id` stale.

**D.12 — Deletion navigation is scoped.** `handle_info({:agent_deleted, _deleted_id}, ...)`
(`agent_live/show.ex:609`) and `{:project_deleted, _deleted_id}` (`project_live/show.ex:129`)
ignore the id and navigate away on any deletion. `IssueLive.Show` already does this correctly at
`:1093`; its second unscoped clause at `:1150` should be removed.

**D.13 — Rollback error paths render.** `render(:error, "Cannot rollback ...")` passes a string
where assigns are expected (`document_controller.ex:91`), and the changeset branch sets
`put_view(html: CymphoWeb.ErrorJSON)` — a JSON view registered under the `html` key (`:96`).

**D.14 — Redaction tolerates degenerate secrets.** `String.replace(acc, secret, ...)`
(`redaction.ex:8`) inserts the placeholder between every character when `secret == ""`, and
raises on `nil` or non-binary. The list SHALL be filtered to non-empty binaries first.

**D.15 — Preview proxy accepts all methods and a root path.** `router.ex:336` defines only
`get ".../proxy/*path"`. Phoenix globs require at least one segment, so `/proxy` 404s, and
POST/PUT/DELETE to a previewed dev server are unroutable.

---

# Non-Functional Requirements

- **Security:** Tenant boundaries enforced at the database level and on every broadcast. No
  credential, secret, or cross-company payload in logs or events.
- **Reliability:** A failure handling one item must not abort the batch (D.1, D.2). Prefer
  logging and continuing over hard pattern matches in loops.
- **Testing:** Every claimed fix ships with one focused regression test that fails before the
  change. No exceptions — this spec's own rejection rate is the argument for it.

---

# Rejected claims — do not re-add

| Draft ref | Claim | Why rejected |
|---|---|---|
| 3.1 | Missing `alg` validation lets attackers forge JWTs | **False.** `verify_signature/4` never dispatches on the header — it always recomputes HS256 with the server secret (`agent_auth_jwt.ex:128-142`), so `alg: none` is inert. `pad_to_length/2` zero-padding is ugly but needs the key to exploit. Optional hygiene, not a vulnerability. |
| 2.4 | `Secrets.get_company_secret_value/2` must filter by company | Function does not exist. `get_company_secret/2` is already scoped (`secrets.ex:94-99`). Unscoped `get_secret_value!/1` (`:107`) has zero callers. |
| 2.8 | `cast_vote/4` allows cross-tenant voting | Already guarded at the only call site: `Companies.is_board_member?` plus a company-scoped fetch (`board_approval_live/show.ex:22,33`). |
| 5.7 | AgentActions must emit rejection comments | Already implemented (`maybe_emit_rejection_comment/2`). |
| 1.6 | Heartbeat topic mismatch | Mismatch is real (`events.ex:150` vs `:195`) but `subscribe_to_heartbeats/1` has **zero callers**. Dead code — delete it or leave it, don't "fix" it. |
| 4.4 | `/projects/:id/edit` raises `FunctionClauseError` | **False.** The route passes no action (`router.ex:118`), so `live_action` is `nil` and `apply_action(socket, nil, id)` delegates to `:show` (`project_live/show.ex:27`). The real issue is cosmetic: the edit URL silently renders the show page. |
| 6.9 | `AutoAssignmentReassigner` raises `KeyError` on `:status` | The sole producer always sends `%{status: ..., company_id: ...}` (`agent_heartbeat.ex:492`). No reachable failure. |
| 5.2 | `run_with_timeout/3` passes `nil` or crashes | Already handles `{:ok, _}`, `{:exit, _}` and `nil` correctly (`health_checker.ex:228-249`). |
| 1.4 | Throttle `BroadcastDedup` inline sweeps | Would need ~100k broadcasts/sec to hold 50k live rows inside a 500 ms window. Not reachable. |
| 1.3 | Strip timestamps from the dedup digest | No evidence of a broadcast storm, and stripping volatile keys risks suppressing genuinely distinct events. Needs a measured problem first. |
| 1.8 | Heartbeat throttle recorded before the token-bucket check | Real ordering quirk (`company_channel.ex:87-88`), but the client is already rate-limited; costs it one extra second. Cosmetic. |
| 4.1 | Blanket catch-all `handle_info` across ~10 LiveViews | Crashes are real (none of the sampled files have one) but self-healing via remount. A blanket catch-all permanently silences the *next* message you did mean to handle. Add one only where a crash is demonstrated. |
| 6.4 | `FOR UPDATE` lock in `notify_children_completed/1` | `WakeupQueue.enqueue/1` already dedups pending wakes on `agent_id + reason + issue_id` (`wakeup_queue.ex:52-58`), absorbing the duplicate. |
| 5.6 | Normalise `issue_id: ""` in `WakeupQueue` | No caller passes `""`. Speculative. |
| 3.8 | `Socket.connect/3` must return `{:error, :unauthorized}` consistently | Bare `:error` (`socket.ex:36`) is a documented Phoenix return. No behavioural difference. |
| 2.9 | `mark_all_read` must be company-scoped | Real that it is arity 1 and spans companies (`issue_read_states.ex:164`), but it touches only the caller's **own** read markers — not a tenancy leak. Downgraded. It also carries an N+1 (`:178`), a separate concern. |

Additional factual corrections to the draft: `should_broadcast?/3` returns booleans, not
`{:ok, :broadcast} | {:ok, :deduplicated}` (`broadcast_dedup.ex:52-62`); `mark_all_read` is
arity 1, not 2; `HeartbeatEngine.record_usage_event/1` and `Decisions.Executor.cancel_project/2`
are both private, not public interfaces.

---

# Deferred — real, but needs a decision first

- **Adapter fallback config contamination** (draft 5.9). `Registry.resolve_agent/1` passes the
  same `config` to whichever fallback adapter it lands on (`registry.ex:164-177`), so a
  `claude_code` config's `model`/`command` keys reach an unrelated adapter. Real, but "strip
  adapter-specific keys" is underspecified — which keys, and per adapter or globally? Needs a
  declared per-adapter config schema first.
- **`AgrentingAdapter` poll interval** (draft 5.4). `poll_interval/1` (`agrenting_adapter.ex:376`)
  applies no bounds, so a config of `0` yields a tight HTTP loop. Only reachable via admin-set
  agent config. Clamping is a one-liner; the open question is clamp-silently vs reject-at-validation.

# Unverified — not scheduled

These draft criteria were **not** checked and must be verified before anyone implements them:
4.3, 4.7, 4.8, 4.9, 5.3, 6.3, 7.1, 7.2, 7.3, 7.4, 7.5, 7.7, 7.9, 7.10, 7.11, 7.13.
The rejection rate on the checked half of this spec was roughly one in three.

# Out of Scope

- Redesigning agent prompt templates or replacing the Ecto/PostgreSQL adapter.
- New notification providers beyond email, Telegram and webhooks.
- Changing the Phoenix Channel or LiveView wire protocols.
- The dead `show_revision_diff` LiveView handler (`issue_live/show.ex:1036`) and its three
  `selected_revision_diff` assigns — unreferenced by any template. Leave or delete; do not build
  on it.

---

# Tasks

Four tranches. Each is independently revertable and separately committable.

## Tranche A — dead subsystems

- [ ] 1. Normalise adapter health status
  - Files: `lib/cympho/adapters/health_checker.ex` (edit)
  - Purpose: Make adapter failures actually count, so agents reach `:error` and recover.
  - Do:
    1. Add `defp normalize_health_status/1`: `:healthy` → `:healthy`; `:degraded` → `:degraded`; everything else (`:unhealthy`, `:unknown`, any unrecognised atom) → `:unavailable`.
    2. In `process_health_result/3`, apply it to `health_result.status` before the `cond`.
    3. Leave the eight adapters untouched — the checker owns the vocabulary it branches on.
  - Details:
    - Keep the `true ->` fallback branch; after normalisation it should be unreachable for real statuses.
  - Check: new test asserts an agent whose adapter reports `:unhealthy` reaches `status: :error` after `@max_consecutive_failures` checks and returns to `:idle` on recovery.
  - _Leverage: `lib/cympho/adapters/health_checker.ex`_
  - _Requirements: A.1_

- [ ] 2. Fix EventStore purge ordering
  - Files: `lib/cympho/event_store.ex` (edit)
  - Purpose: Keep the per-topic index newest-first so replay works after the first purge tick.
  - Do:
    1. In `drop_old_ids/2`, return `{kept_rev, evicted}` — delete the trailing `Enum.reverse/1`.
    2. Rename `kept_rev` to `kept` and correct the surrounding comment.
  - Details:
    - The reduce already produces newest-first because it prepends over a reversed list.
  - Check: new tests — append 3 events, `purge_old(300_000)` (evicts nothing), assert `fetch_since/2` returns the tail chronologically and `fetch_since(topic, nil, 2)` returns the two newest.
  - _Leverage: `test/cympho/event_store_test.exs`_
  - _Requirements: A.2_

- [ ] 3. Repair the document diff end to end
  - Files: `lib/cympho/documents.ex` (edit), `lib/cympho_web/controllers/document_controller.ex` (edit), `lib/cympho_web/controllers/document_json.ex` (edit)
  - Purpose: Make revision comparison return a correct result instead of raising.
  - Do:
    1. Replace `compute_line_diff/3`, `diff_lines/4` and `find_common_sequence/4` with a common-prefix / common-suffix trim (~20 lines): shared head lines → `:same`, shared tail lines → `:same`, remaining old → `:deletion`, remaining new → `:addition`.
    2. Emit one flat list of `%{type: :same | :addition | :deletion, line: line}`.
    3. Keep `get_diff/2` returning `%{current:, other:, diff:}`.
    4. Change the controller to `render(conn, :diff, result: diff)`.
    5. Change `DocumentJSON.diff/1` to read `result.other` as `base` and `result.current` as `target`.
  - Details:
    - Document the limitation in a comment: scattered edits degrade to delete-all + add-all. That is the same intent the original code had, implemented correctly.
    - Do not touch the dead `show_revision_diff` LiveView handler.
  - Check: new tests — `get_diff/2` returns the expected op list for an insertion, a deletion and a mid-file edit; `GET /issues/:issue_id/documents/:key/revisions/:revision_id/diff` returns 200 with a well-formed body.
  - _Leverage: `test/cympho/documents_test.exs`_
  - _Requirements: A.3_

## Tranche B — security and tenancy

- [ ] 4. Block protocol-relative redirects
  - Files: `lib/cympho_web/controllers/company_switcher_controller.ex` (edit)
  - Purpose: Close the open redirect.
  - Do:
    1. In `is_safe_path?/1`, reject any path starting with `//` or `/\` before the existing checks.
  - Check: new test — `return_to` of `//evil.com` and `/\evil.com` both redirect to `/`.
  - _Requirements: B.1_

- [ ] 5. Accumulate chunked webhook bodies
  - Files: `lib/cympho_web/cache_body_reader.ex` (edit)
  - Purpose: Stop >1 MB webhooks from 500ing before HMAC verification.
  - Do:
    1. Handle `{:more, partial, conn}` by recursing and accumulating until `{:ok, ...}`.
    2. Preserve the existing `[body | assigns[:raw_body]]` iodata shape.
  - Details:
    - `github_controller.ex:258` already flattens the list; do not change it.
  - Check: new test — a body larger than `:read_length` yields the full binary and a passing HMAC.
  - _Requirements: B.2_

- [ ] 6. Scope governance broadcasts by company
  - Files: `lib/cympho/principal_permissions.ex` (edit), `lib/cympho/governance_audit_logs.ex` (edit)
  - Purpose: Remove the latent cross-tenant leak on two global PubSub topics.
  - Do:
    1. Route both broadcasts through `Cympho.PubSubGuard.company_broadcast/3` on `company:#{company_id}:principal_permissions` and `company:#{company_id}:governance_audit`.
    2. Change `subscribe/0` to `subscribe/1` taking `company_id`.
    3. Drop the broadcast when `company_id` is nil or blank.
  - Check: new test — a grant in company A is not delivered to a subscriber in company B; a nil `company_id` broadcasts nothing.
  - _Leverage: `lib/cympho/pub_sub_guard.ex`_
  - _Requirements: B.3_

- [ ] 7. Enforce tenancy on skill assignment
  - Files: `lib/cympho/skills.ex` (edit)
  - Purpose: Stop a client-controlled `plugin_id` from crossing companies.
  - Do:
    1. In `assign_skill_to_agent/3`, load the agent and the plugin and verify `agent.company_id == plugin.company_id`.
    2. Return `{:error, :company_mismatch}` on divergence.
  - Details:
    - `agent_live/show.ex:512` already ignores the return value; leave it, the reject is enough.
  - Check: new test — assigning company B's plugin to company A's agent returns `{:error, :company_mismatch}`.
  - _Requirements: B.4_

- [ ] 8. Company-scope the global unique indexes
  - Files: `priv/repo/migrations/<timestamp>_scope_multi_tenant_unique_indexes.exs` (new), `lib/cympho/projects/project.ex` (edit), `lib/cympho/labels/label.ex` (edit), `lib/cympho/tool_call_traces/tool_call_trace.ex` (edit), `lib/cympho/decisions/decision.ex` (edit)
  - Purpose: Let separate tenants use the same label name, project prefix and decision key.
  - Do:
    1. `drop_if_exists` then recreate: `labels [:company_id, :name]`, `projects [:company_id, :prefix]`.
    2. Recreate the decisions index as `[:company_id, :decision_key, :parent_decision_id]` keeping `where: "status = 'active'"`. Do **not** add a NULL-partial index.
    3. `drop_if_exists tool_call_traces_content_hash_index` and do **not** recreate it — `chain_hash` carries the tamper evidence and any composite still collides within a company inside one second.
    4. Update the matching `unique_constraint/2` calls, including index names, in the four schemas. Remove `unique_constraint(:content_hash)` from `tool_call_trace.ex:77`.
  - Details:
    - Relaxing a unique constraint is data-safe; no backfill needed.
  - Check: new tests — two companies each create a `bug` label, an `ENG` project and an active `arch_v1` child decision; all succeed. `mix ecto.reset` runs clean.
  - _Requirements: B.5_

## Tranche C — authentication

- [ ] 9. Check for email collisions before normalising
  - Files: none (investigation only)
  - Purpose: Determine whether the C.1 backfill is safe.
  - Do:
    1. Query for rows whose downcased email collides with another user's.
    2. If any exist, stop and record the merge policy question under "## Blockers".
  - Check: query returns zero rows, or a blocker is recorded.
  - _Requirements: C.1_

- [ ] 10. Normalise emails on registration and authentication
  - Files: `lib/cympho/users/user.ex` (edit), `lib/cympho/authentication.ex` (edit), `priv/repo/migrations/<timestamp>_downcase_user_emails.exs` (new)
  - Purpose: Make login work regardless of casing and stop duplicate accounts.
  - Do:
    1. In `validate_email/1`, add `update_change(:email, &(&1 |> String.trim() |> String.downcase()))` so both `changeset/2` and `registration_changeset/2` inherit it.
    2. Downcase the lookup in `authenticate_user/2`.
    3. Add a migration backfilling existing rows to lowercase.
  - Details:
    - Only run after task 9 reports no collisions.
  - Check: new test — register `Alice@Example.Com`, authenticate as `alice@example.com`, succeeds.
  - _Requirements: C.1_

- [ ] 11. Hash passwords and make user provisioning atomic
  - Files: `lib/cympho/users.ex` (edit), `lib/cympho_web/controllers/user_controller.ex` (edit)
  - Purpose: Stop `POST /api/users` minting accounts that can never log in.
  - Do:
    1. In `create_user/1`, use `registration_changeset/2` when `attrs` carries a password, else `changeset/2`.
    2. In `UserController.create/2`, wrap the user insert and the membership insert in one `Ecto.Multi`.
  - Check: new tests — a user created via the API authenticates with the submitted password; a membership failure leaves no orphan user.
  - _Requirements: C.2_

- [ ] 12. Allow company bootstrap and non-member join requests
  - Files: `lib/cympho_web/plugs/user_auth.ex` (edit), `lib/cympho_web/controllers/company_controller.ex` (edit)
  - Purpose: Unblock two endpoints that cannot currently be called.
  - Do:
    1. In `UserAuth`, generalise `accept_invite_action?/1` to a `bootstrap_action?/1` also matching `:create` and `:import_company` on `CompanyController`.
    2. Remove `:create_join_request` from the `CompanyAccess` plug action list.
    3. In `create_join_request/2`, verify the company exists and return the same 404 shape on miss, so company existence is still not probeable.
  - Check: new tests — a zero-membership user creates a company; a non-member submits a join request; a non-member targeting a non-existent company still gets 404.
  - _Requirements: C.3, C.4_

- [ ] 13. Make duplicate invite acceptance idempotent
  - Files: `lib/cympho/companies.ex` (edit)
  - Purpose: Stop a 500 when an existing member clicks an invite link.
  - Do:
    1. In `accept_invite/2`, check for an existing membership before `create_membership!/1` and treat it as success, still marking the invite accepted.
  - Check: new test — accepting the same invite twice returns `{:ok, ...}` both times.
  - _Requirements: C.5_

## Tranche D — correctness and robustness

- [ ] 14. Skip unknown notification channels
  - Files: `lib/cympho/notifications/dispatcher.ex` (edit)
  - Purpose: Stop one bad preference row from killing every channel for that user.
  - Do:
    1. Replace `String.to_existing_atom/1` + `Map.fetch!/2` with a `resolve_channel_module/1` returning `{:ok, module}` or `:ignore`.
    2. Filter out `:ignore` with a debug log before spawning tasks.
  - Check: new test — a preference row with `channel_type: "carrier_pigeon"` is skipped and the remaining channels still deliver.
  - _Requirements: D.1_

- [ ] 15. Continue project cancellation past a refused transition
  - Files: `lib/cympho/decisions/executor.ex` (edit)
  - Purpose: Stop a half-executed `cancel_project` decision.
  - Do:
    1. Replace the `{:ok, _} =` match at `executor.ex:107` with a `case` that logs a warning on error and continues.
  - Check: new test — a project with one untransitionable issue still archives, and the other issues cancel.
  - _Requirements: D.2_

- [ ] 16. Wrap swarm launch in a transaction
  - Files: `lib/cympho/issues/swarm.ex` (edit)
  - Purpose: Stop partial launches orphaning agents and issues.
  - Do:
    1. Wrap `do_launch/2` in `Repo.transaction`, returning `{:error, reason}` on any step failure.
  - Check: new test — a forced failure mid-launch leaves no temporary agents and no worker issues.
  - _Requirements: D.3_

- [ ] 17. Return descendant trees in pre-order
  - Files: `lib/cympho/issues.ex` (edit)
  - Purpose: Make tree rendering show parents before children.
  - Do:
    1. Rework `walk_descendants/4` so each node precedes its own subtree, siblings ascending, and drop the caller's `Enum.reverse/1` at `issues.ex:260`.
  - Check: new test — a 3-level tree returns exact depth-first pre-order.
  - _Requirements: D.4_

- [ ] 18. Fix read-state deletion fallback and ordering
  - Files: `lib/cympho/issue_read_states.ex` (edit)
  - Purpose: Stop an `ArgumentError` and make unread targeting deterministic.
  - Do:
    1. Replace `drop_while(...) |> tl()` at `:70` with a `case` handling `[]`.
    2. Replace the UUID comparison at `:220` with `rs.last_read_at < ^comment.inserted_at or is_nil(rs.last_read_at)`.
  - Check: new tests — unread count is correct after the last-read comment is deleted; `notify_new_comment/2` selects users by timestamp.
  - _Requirements: D.5_

- [ ] 19. Validate budget limits independently
  - Files: `lib/cympho/budgets/budget.ex` (edit)
  - Purpose: Reject negative limits on create.
  - Do:
    1. In `validate_amounts/1`, validate `limit_amount` whenever it is present, not only alongside `spent_amount`.
  - Check: new test — a budget with a negative `limit_amount` and no `spent_amount` is rejected with "must be positive".
  - _Requirements: D.6_

- [ ] 20. Broadcast comments on project-less issues
  - Files: `lib/cympho_web/events.ex` (edit)
  - Purpose: Restore real-time comments for issues with no project.
  - Do:
    1. Add a clause broadcasting to `company:#{company_id}:comments` when `company_id` is present and `project_id` is nil or blank. Keep the fail-closed `_ -> :ok` for a missing/blank `company_id`.
  - Check: new test — a comment on a project-less issue is broadcast on the company topic.
  - _Requirements: D.7_

- [ ] 21. Forward the join payload to subtopic channels
  - Files: `lib/cympho_web/company_channel.ex` (edit)
  - Purpose: Make replay work on subtopics, not just the bare company topic.
  - Do:
    1. Pass `payload` instead of `%{}` in all four `dispatch_sub_topic/4` clauses.
    2. Ensure each delegate channel assigns `last_event_id` and replays on `:after_join`.
  - Check: new test — joining `company:<id>:issues` with a `last_event_id` receives `"replay"` pushes.
  - _Requirements: D.8_

- [ ] 22. Bill runs that have no issue
  - Files: `lib/cympho/heartbeat_engine.ex` (edit)
  - Purpose: Stop silently dropping token spend.
  - Do:
    1. Restructure `record_usage_event/1` so a missing or deleted issue falls back to `run.company_id`, leaving `issue_id`/`project_id`/`goal_id` nil.
  - Check: new test — a run with `issue_id: nil` and non-zero tokens records usage against `run.company_id`.
  - _Requirements: D.9_

- [ ] 23. Respect the Kanban project filter and Inbox unsubscribe
  - Files: `lib/cympho_web/live/kanban_live/index.ex` (edit), `lib/cympho_web/live/inbox_live/index.ex` (edit)
  - Purpose: Stop leaking other projects onto a filtered board and stop stale inbox subscriptions.
  - Do:
    1. In `handle_info({:issue_created, issue}, socket)`, ignore issues whose `project_id` differs from a non-nil `selected_project_id`.
    2. In `maybe_subscribe_to_agent/1`, add a branch for `agent_id == "all"` that unsubscribes from `subscribed_agent_id` and sets it to `nil`.
  - Check: new tests — a filtered board ignores another project's `:issue_created`; switching to "all" clears `subscribed_agent_id`.
  - _Requirements: D.10, D.11_

- [ ] 24. Scope deletion navigation
  - Files: `lib/cympho_web/live/agent_live/show.ex` (edit), `lib/cympho_web/live/project_live/show.ex` (edit), `lib/cympho_web/live/issue_live/show.ex` (edit)
  - Purpose: Stop bouncing users off a page when a different record is deleted.
  - Do:
    1. In agent and project show, compare the deleted id against the displayed record before navigating.
    2. Remove the redundant unscoped `{:issue_deleted, _deleted_id}` clause at `issue_live/show.ex:1150`.
  - Check: new tests — viewing agent A, deleting agent B leaves the page mounted; deleting agent A navigates away.
  - _Requirements: D.12_

- [ ] 25. Fix rollback error rendering and redaction guards
  - Files: `lib/cympho_web/controllers/document_controller.ex` (edit), `lib/cympho/secrets/redaction.ex` (edit)
  - Purpose: Make two error paths behave.
  - Do:
    1. In `rollback/2`, render both error branches through `CymphoWeb.ErrorJSON` with a proper assigns map.
    2. In `redact/2`, filter `secrets` to non-empty binaries before the reduce.
  - Check: new tests — a rollback blocked by pending approvals returns 422 with a JSON body; `redact/2` with `["", nil, "real"]` redacts only `"real"` and does not raise.
  - _Requirements: D.13, D.14_

- [ ] 26. Support preview proxy root path and all methods
  - Files: `lib/cympho_web/router.ex` (edit), `lib/cympho_web/controllers/preview_controller.ex` (edit)
  - Purpose: Make workspace previews usable for real apps, not just GET on a sub-path.
  - Do:
    1. Add `match :*, "/preview/:service_id/proxy", PreviewController, :proxy` and change the glob route to `match :*`.
    2. Forward the request body and normalised headers for non-GET methods.
  - Check: new tests — `POST /api/preview/:id/proxy` and `GET /api/preview/:id/proxy` both reach the controller.
  - _Requirements: D.15_

- [ ] 27. Full-suite verification
  - Files: `test/` (verify)
  - Purpose: Prove the tranches are regression-free.
  - Do:
    1. `mix compile --warnings-as-errors`
    2. `mix test`
    3. `mix format --check-formatted`
    4. `mix credo` — no new warnings on touched files
    5. `mix cympho.compare` — still 0 gaps
  - Check: `mix test` prints "0 failures".
  - _Requirements: A.1 - D.15_

---

# How to implement

1. Read the Requirements section for the task's `_Requirements:_` refs, then work the tasks in
   order, one at a time.
2. Write the failing test **first**, confirm it fails for the stated reason, then fix.
3. Only touch the files the current task names.
4. After each task, run `mix compile --warnings-as-errors` and the tests named by the task. When
   they pass, change `- [ ]` to `- [x]` and move on.
5. Commit at each tranche boundary (after tasks 3, 8, 13, 26).
6. If something the spec names does not exist, or a check fails twice: stop. Describe the problem
   under "## Blockers". Do not guess and do not work around it.
7. Do not implement anything from "Rejected claims", "Deferred" or "Unverified" without
   re-verifying it first and recording the evidence here.

## Blockers

None
