# Lightweight runtime and Paperclip gap audit

**Date:** 2026-09-25
**Cympho baseline:** `ec273cf` (2026-09-23)
**Scope:** direct/gateway runtime reliability, tenant safety, resource bounds, and a current public Paperclip comparison.

## External evidence

The official Paperclip repository currently reports:

- Stable release `v2026.916.1`, commit `d554c4789ed3930f8a53ac9fdf6503b3187097da`, released 2026-09-21.
- `master` commit `efce9356b553a08f77a5877bb0ceac68d2cc4ad8`, dated 2026-09-25T00:36:45Z.
- The release page reports 142 commits from `v2026.916.1` to `master`.

Primary sources: [release page](https://github.com/paperclipai/paperclip/releases/tag/v2026.916.1), [official README](https://github.com/paperclipai/paperclip/blob/master/README.md), and GitHub ref/commit metadata. Tavily searches were used for focused public-source discovery only; snippets, star counts, and third-party comparisons are not treated as performance evidence.

The latest release fixes a task-conversation composer pause-status race and restores retryable classification for duplicate document inserts. These are not automatically Cympho gaps: Cympho must have the same UI/API flow before a parity claim is meaningful.

## Changes landed in this tranche

1. **Absolute gateway deadlines and bounded streaming.** HTTP and OpenAI Chat now pass both `receive_timeout` (per-chunk compatibility) and `request_timeout` (absolute HTTP/1 deadline) to Finch. Their `stream_while` reducers stop at the existing response caps instead of consuming the rest of an overflow response. Finch 2-/3-tuple errors and response trailers are handled without crashing the adapter worker.
2. **OpenClaw safety and memory bounds.** OpenClaw now reuses `HttpAdapter.validate_public_url/1` at configuration, request, and health boundaries. It uses Finch streaming rather than `:httpc` response materialization, caps task/error/health bodies at 5 MiB, halts on overflow, handles Finch errors, and does not follow redirects into a private host. The unnecessary `:inets` startup was removed.
3. **Agrenting bounds and deadlines.** REST and MCP POST responses use a capped streaming reducer, including error responses. MCP SSE buffering is bounded and stream failures are delivered to the waiting exchange. `receive_timeout` and `request_timeout` are both forwarded; configured body limits cannot exceed the 4 MiB ceiling while smaller limits remain supported.
4. **Project tenant immutability.** `Project.changeset/2` casts `company_id` only for new records; ordinary updates use an update changeset that cannot move a project between companies. A LiveView regression proves forged `company_id` input cannot change ownership while normal edits still persist.

## Lightweight-agent architecture findings

The direct OpenAI-compatible adapter is currently one request/turn: it builds a prompt, sends `/chat/completions`, parses final text, and lets the orchestrator parse `cympho-actions` afterward. It has no provider-native tool-call continuation, streamed progress protocol, idempotency key, or durable conversation checkpoint. CLI adapters provide richer coding loops but carry external harness process trees and opaque child RSS.

Recommended staged direction (not yet implemented):

1. Instrument prompt bytes/tokens, provider TTFB/latency, output bytes, retry/fallback, unique child-PID RSS/PSS, cgroup peak/current, and orphan/slot leaks.
2. Add an opt-in native BEAM gateway loop with allowlisted workspace tools, hard prompt/output/tool/wall-clock budgets, idempotency keys, streamed deltas, and a checkpoint after every tool result. Reuse existing workspace authorization, `AgentActions`, traces, budgets, and OTP cancellation.
3. Add deterministic pre-dispatch context compaction: preserve current task and action contract, summarize/truncate older history and attachments before serializing the provider payload, and measure the prompt/RSS slope.
4. Keep CLI adapters as a compatibility lane, but add Linux cgroup/RLIMIT custody and a supervised process-tree custodian. Use a sidecar only if native provider compatibility requires it.

Acceptance gates for any native loop: a deterministic edit-test fixture; at least 95% completion with required evidence; at most 5% malformed/no-output; zero unauthorized filesystem writes/tool calls; zero orphan children or slot leaks; cancellation p95 under two seconds; restart resume at least 90%; and no OOM/sustained swap. Compare native and CLI paths on the same Linux cgroup-limited host with at least 20 repetitions. Do not claim “10×” from idle-only or macOS samples.

## Gap matrix

| Area | Cympho evidence | Status / next step |
| --- | --- | --- |
| Workspaces/runtime | `lib/cympho/workspaces/` provides leases, probes, services, and previews. | Strong parity. Durable process/listener identity for safe service adoption after restart remains open (see `paperclip_gap.md` L3a). |
| Heartbeat execution | DB-backed wake queue, budget checks, recovery, and event-driven delegated idle workers. | Cympho has a measured idle-RAM advantage over its legacy timer path; reproduce 100/500/1,000-agent cells in an equivalent Linux slice. |
| Governance/budgets | Approvals, execution policies, decisions/reversal, audit logs, and budget hard stops. | Deep control-plane parity/differentiation; retain owner-readable evidence and tenant scoping. |
| Persistent coding state | `HeartbeatEngine.Run` stores continuation/session metadata, but direct gateway turns are one-shot. | Open gap: native streamed tool loop plus checkpoint/resume. |
| Skills/context | Skills loader/hot reload and bounded attachment/history pieces exist. | Partial: no hard pre-dispatch context budget; add compaction and measure prompt/RSS behavior. |
| Portability/install | Import/export and diagnostics/readiness exist. | Partial: V1 materializes a decoded transfer map; export/history fidelity and managed repair/update remain incomplete. |
| Current Paperclip release fixes | Composer pause-race and duplicate-document conflict classification. | Not a direct gap without the same flow; add targeted parity only if Cympho exposes it. |

## Residual risks

- `HttpAdapter.validate_public_url/1` blocks literal private/metadata IPs but does not resolve DNS answers; DNS rebinding remains an open SSRF risk requiring request-time, fail-closed resolution and redirect policy.
- OpenAI Chat still promotes `reasoning_content`/`reasoning`/`thinking` to final output when content is blank. This may expose private reasoning or action-like text; compatibility behavior needs an explicit provider-capability decision and regression test before changing.
- Local Port adapters have bounded BEAM accumulation but no universal OS-level RSS/CPU containment; a runaway descendant can retain a slot until cleanup/recovery.
- The full suite remains non-green: this tranche's fresh run had **4,672 tests, 7 failures**. The seven identities are the README `CLAUDE.md` link plus the six pre-existing Orchestrator completion/action-contract failures recorded in the 2026-09-23 baseline; no new failure identity was attributed to this tranche. The focused results below must not be presented as whole-suite green.

## Verification recorded

- RED: the new Finch 3-tuple/trailer tests reproduced worker crashes in the pre-fix reducers.
- GREEN: focused changed-path run: **107 tests, 0 failures**.
- GREEN after reducer compatibility fixes: HTTP/OpenAI/OpenClaw adapter run: **64 tests, 0 failures**.
- Agrenting focused client and adapter runs: **5 and 9 tests, 0 failures** (serialized disposable test DB runner).
- `mix compile --warnings-as-errors` completed successfully; changed files pass `mix format --check-formatted` and `git diff --check`.
- Full serialized suite: **4,672 tests, 7 failures**, same seven baseline identities; log `acceptance2-tests-1790337715416214000.log`.
- No provider credentials, paid model calls, deployment, browser session, cookie, or local-storage changes were used.

After that verification completed, unrelated concurrent edits appeared in `README.md` and `test/cympho/orchestrator_test.exs`; they are intentionally not part of this tranche and were not re-verified here.
