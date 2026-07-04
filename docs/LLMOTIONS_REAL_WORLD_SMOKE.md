# LLMotions Real-World Smoke Run

This playbook verifies that Cympho can run a realistic autonomous company loop
with LLMotions-backed executive agents, then hand implementation to a
repo-capable engineering runtime.

## Assumptions

- `https://cli.llmotions.com/v1` exposes an OpenAI-compatible
  `/chat/completions` API.
- Store provider credentials in Cympho Secrets as `LLMOTIONS_API_KEY`.
  `OPENAI_API_KEY` is still accepted as a compatible-gateway fallback.
- LLMotions `openai_chat` profiles are text/action runtimes. They can plan,
  delegate, review evidence, and emit `cympho-actions`; they cannot edit files,
  run local tests, open branches, or create PRs by themselves.
- For implementation issues, use a repo-capable engineer profile such as Codex,
  Claude Code, Cursor, Process Codex, Agrenting push delivery, or another
  configured coding runtime.

## Provider Ping

Run this outside the app before the first smoke run:

```bash
export LLMOTIONS_API_KEY="..."

python3 - <<'PY'
import json, os, urllib.request

payload = {
  "model": "gemma-4-31b",
  "messages": [
    {"role": "system", "content": "Reply with one short sentence."},
    {"role": "user", "content": "Cympho smoke check: say READY and name one platform behavior to test."}
  ],
  "temperature": 0.1,
  "max_tokens": 80
}

req = urllib.request.Request(
  "https://cli.llmotions.com/v1/chat/completions",
  data=json.dumps(payload).encode(),
  headers={
    "Authorization": "Bearer " + os.environ["LLMOTIONS_API_KEY"],
    "Content-Type": "application/json",
    "Accept": "application/json"
  },
  method="POST"
)

with urllib.request.urlopen(req, timeout=45) as resp:
  data = json.loads(resp.read().decode())
  print(resp.status, data.get("model"), data["choices"][0]["message"]["content"].strip())
PY
```

Expected result: HTTP `200`, model `gemma-4-31b`, and a short content string.

## Setup

1. Start from a migrated dev database:

```bash
mise exec -- mix setup
```

2. Create the focused LLMotions smoke company:

```bash
export LLMOTIONS_API_KEY="..."
mise exec -- mix cympho.llmotions_smoke --yes
```

The task creates a timestamped company, stores `LLMOTIONS_API_KEY` as an
encrypted company-scoped secret, configures CEO/CTO as LLMotions chat agents,
configures engineer/QA as repo-capable process agents, creates a primary project
workspace pointing at the current repo, creates the Team Pulse CEO mission issue,
pins it for focused dispatch, and prints the exact runtime command to run next.

By default repo-capable agents run against the current directory. Override or
disable that behavior when needed:

```bash
mise exec -- mix cympho.llmotions_smoke --repo-cwd /path/to/repo --yes
mise exec -- mix cympho.llmotions_smoke --no-workspace --yes
```

Use alternate executive models for comparison:

```bash
mise exec -- mix cympho.llmotions_smoke --model gemini-3.5-flash-low --yes
mise exec -- mix cympho.llmotions_smoke --model gemini-3.5-flash --yes
```

3. Start Cympho in normal UI mode if you want to inspect before dispatch:

```bash
mise exec -- mix phx.server
```

4. Open the app, sign in, and confirm the company-scoped secret exists:

```text
Settings -> Secrets -> Add runtime secret
Key: LLMOTIONS_API_KEY
Scope: company
Value: your LLMotions key
```

If you used the Mix task with `LLMOTIONS_API_KEY` set, this is already done.

5. Confirm CEO and CTO agents:

```text
Runtime profile: OpenAI Chat LLMotions Gemma
Adapter: OpenAI Chat
Model: gemma-4-31b
Endpoint: https://cli.llmotions.com/v1
Max concurrent jobs: 1
```

6. Confirm at least one implementation engineer with a repo-capable runtime.
Use `Process Codex CLI` for a local low-cost coding lane, or another runtime
that can actually change files and run tests.

Process Codex runs Codex headlessly with `codex exec`, `--sandbox
workspace-write`, and stdin prompt delivery. Plain `codex` opens the interactive
TUI and will fail under the process adapter because stdin/stderr are not a TTY.

7. Open `Operations` and check that:

- runtime services are ready or explain the exact missing gate;
- adapter preflight reports the LLMotions CEO and CTO as ready;
- repo delivery coverage names a repo-capable engineer;
- no secret value appears in the page.

## First Focused Smoke

Use the built-in Operations smoke first:

```text
Operations -> CEO flow verification -> Create CEO to CTO smoke
```

Then launch only that issue under a microscope. Operations shows a copyable
command, equivalent to:

```bash
CYMPHO_DISPATCH_ONLY_ISSUE_ID=<issue_id> \
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_START_HEARTBEAT_WATCHDOG=1 \
CYMPHO_START_HEALTH_CHECKER=1 \
mise exec -- mix phx.server
```

Expected result:

- CEO starts the parent issue.
- CEO creates or routes exactly one CTO-owned child issue.
- Parent is blocked with a restart packet while waiting on CTO evidence.
- Operations shows delegated work and the CEO outcome monitor.
- No provider key appears in comments, logs, run metadata, or UI snapshots.

## Real App Scenario

After the focused smoke passes, create this owner issue for the CEO.

```text
Title:
Build Team Pulse launch tracker

Description:
Build a small usable internal app that helps a startup leadership team track
launch readiness. The first version should let a user create launch items,
mark owners, set status, see blocked work, and read a concise readiness summary.

Business outcome:
The owner can use the app to decide whether a weekly product launch is ready,
blocked, or needs escalation.

Constraints:
Do not claim implementation from a text-only chat runtime. CEO and CTO should
plan, route, review, and package evidence. Implementation must be delegated to a
repo-capable engineer.

Acceptance criteria:
- CEO creates a CTO planning/spec child with clear evidence and verification.
- CTO turns the spec into implementation and QA work with dependency order.
- Engineer delivers a code change, work product, or PR evidence.
- QA or CTO records smoke coverage for create item, update status, blocked view,
  readiness summary, and empty/error states.
- CEO packages the final owner update with evidence inspected, verification,
  remaining risk, current state, next decision, and restart packet.

Evidence required:
Issue links, comments, work products, PR URL or code artifact, focused test
output, smoke checklist, and final CEO owner update.

Verification required:
Focused automated tests for changed code plus a browser smoke path through the
main readiness workflow. If browser verification cannot run, attach the exact
blocker and next command.

Definition of done:
Owner can accept or request changes from the final CEO update without opening
raw logs.
```

## What To Test

- Company bootstrap: company, mission goal, project, CEO, CTO, engineer, role
  hierarchy, and seed issues.
- Runtime credentials: `LLMOTIONS_API_KEY` preflight readiness, endpoint/model
  display, and no secret leakage.
- Dispatch gates: focused issue dispatch, health checker, heartbeat watchdog,
  and paused-company behavior.
- CEO behavior: owner intake, mission decomposition, child issue creation,
  handoff, blocker with restart packet, and owner-verification closeout.
- CTO behavior: spec review, implementation split, review decision, request
  changes quality, and escalation to CEO.
- Engineer behavior: checkout, code evidence, test evidence, PR/work product,
  submit review, and recovery from missing capability.
- Governance: board approvals, decisions, decision reversal, audit events,
  role permissions, and chain-of-command violations.
- Collaboration UI: issue page, kanban board, Operations, Review Queue, Inbox,
  Activity, Tool Call Traces, Prompt Inspector, and Audit Trail.
- Channels and replay: company activity, issue comments, heartbeats, runs,
  reconnect replay, dedup, and rate limiting.
- Failure recovery: malformed agent output, no output, timeout, stale checkout,
  stuck engineer, missing repo runtime, thin delivery brief, and owner revision.

## Deep Debugging

Provider layer:

```bash
export LLMOTIONS_API_KEY="..."
curl -sS https://cli.llmotions.com/v1/chat/completions \
  -H "Authorization: Bearer $LLMOTIONS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gemma-4-31b","messages":[{"role":"user","content":"say READY"}],"max_tokens":20}'
```

Preflight layer:

```bash
mise exec -- iex -S mix
```

```elixir
alias Cympho.{Agents, Issues, Runtime, RuntimePreflight}
agent = Agents.get_agent!("AGENT_ID")
issue = Issues.get_issue!("ISSUE_ID")
RuntimePreflight.for_agent(agent, autonomy_enabled?: true)
RuntimePreflight.for_issue(issue, autonomy_enabled?: true)
Runtime.preflight(issue, agent, skip_agent_status?: true)
```

Adapter layer:

- Confirm request URL is `https://cli.llmotions.com/v1/chat/completions`.
- Confirm adapter is `Cympho.Adapters.OpenAIChatAdapter`.
- Confirm adapter config includes endpoint/model, but do not print full config
  in shared logs if it may contain `api_key`.
- Compare `gemma-4-31b`, `gemini-3.5-flash-low`, and `gemini-3.5-flash` on the
  same CEO smoke issue. Watch action validity, restart packet quality, and
  unnecessary delegation.

Engineer runtime layer:

- Confirm repo-delivery issues have either an execution workspace/worktree or a
  deliberate shared project workspace. Shared workspaces are acceptable for a
  single focused run, but they are not safe for parallel file edits.
- Seed isolated worktrees with dependencies/build artifacts before expecting
  fast verification. A brand-new worktree may fail before app code compiles if
  dependencies need generated assets that already exist only in the main build.
- Confirm the process command is non-interactive (`codex exec`, not plain
  `codex`).
- Keep the focused runtime alive until the process agent returns a final
  `cympho-actions` block. Stopping the runtime early can leave useful code
  changes in the worktree but no issue comment, work product, or review action.
- After a process run, compare DB evidence with filesystem evidence:

```bash
git -C <execution_workspace_cwd> status --short
git -C <execution_workspace_cwd> diff --stat
```

Orchestrator layer:

```bash
CYMPHO_DISPATCH_ONLY_ISSUE_ID=<issue_id> \
CYMPHO_ORCHESTRATOR_ENABLED=1 \
CYMPHO_START_HEARTBEAT_WATCHDOG=1 \
CYMPHO_START_HEALTH_CHECKER=1 \
mise exec -- mix phx.server
```

Watch for:

- `orchestrator_session_started` in Audit Trail;
- a running row in `heartbeat_runs`;
- issue status transitions `todo -> in_progress -> blocked/in_review/done`;
- comments containing tagged `[handoff]`, `[delivery]`, `[review]`,
  `[owner_update]`, or `[blocked]`;
- child issue `parent_id`, `assigned_role`, `assignee_id`, and company scope;
- work products and PR URL on delivery issues.

Database probes:

```bash
mise exec -- mix run -e '
import Ecto.Query
alias Cympho.{Repo, Issues.Issue, HeartbeatEngine.Run}
issue_id = System.fetch_env!("ISSUE_ID")
IO.inspect(Repo.get!(Issue, issue_id), label: "issue")
IO.inspect(Repo.all(from r in Run, where: r.issue_id == ^issue_id, order_by: [desc: r.inserted_at], limit: 5), label: "runs")
'
```

Recovery probes:

- Missing key: disable `LLMOTIONS_API_KEY`; preflight should point to
  `Settings -> Secrets` and block launch.
- Wrong runtime: assign a repo implementation issue to `openai_chat`; preflight
  should warn that file changes require a repo-capable runtime.
- Thin brief: ask CTO to create an engineer issue without acceptance criteria;
  `AgentActions` should reject it and add a repair scaffold.
- Stuck run: use the existing stuck-engineer recovery test to verify watchdog
  and CTO reassignment behavior.
- Owner revision: after CEO final update, request revision; CEO should address
  the gap instead of repeating the prior update.

## Automated Checks

Run the focused regression set after profile or runtime edits:

```bash
mise exec -- mix test test/cympho/runtime_profiles_test.exs \
  test/cympho/runtime_preflight_test.exs \
  test/cympho/runtime_test.exs \
  test/cympho/integration/mission_better_than_linear_test.exs \
  test/cympho/integration/stuck_engineer_recovery_test.exs
```

Run broader coverage before trusting broad autonomy:

```bash
mise exec -- mix test
```

## Success Criteria

- Provider ping returns HTTP `200`.
- LLMotions CEO and CTO preflight are ready with `LLMOTIONS_API_KEY`.
- Focused CEO smoke creates one CTO child and blocks the parent with a restart
  packet.
- Real app mission reaches engineer delivery, CTO review, CEO owner update, and
  owner accept/request-revision decision.
- Operations, Audit Trail, Review Queue, Inbox, Activity, and issue comments all
  tell the same story.
- No provider secret is visible in logs, UI, comments, work products, or test
  failures.
