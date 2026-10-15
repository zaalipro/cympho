# UI Copy Simplification & Microcopy Audit Log

**Author:** Cympho Engineering Team  
**Date:** 2026-10-15  
**Milestone:** Milestone 3 — App-Wide Human-Friendly UI Copy Simplification & Test Sync  
**Scope:** LiveViews, Components, Navigation, and Synchronized ExUnit Test Suites  

---

## 1. Executive Summary

Cympho is an autonomous AI agent orchestration platform blending enterprise governance, multi-agent operations, and intuitive issue management. As part of Milestone 3, a comprehensive application-wide microcopy audit and overhaul was executed. 

The previous user interface exhibited several anti-patterns:
1. **The "Command" Syndrome:** The word "Command" was ubiquitously affixed to navigation titles, section badges, and card headers (`CEO command lane`, `Activity command`, `Routine command`, `Budget command`, `Cost command`, `Policy command`, `Workspace command`, `Goal command`, `Review command`). This introduced an intimidating, pseudo-military atmosphere instead of an intuitive, modern collaboration tool.
2. **Punitive / Adversarial Phrasing:** Review workflows and brief validators framed human-agent interaction with administrative suspicion and negative judgment (`Return weak submissions`, `kicked back by reviewer`, `Too thin for autonomy`).
3. **Internal Scheduler & Telemetry Leaks:** Low-level implementation details and OTP concepts were surfaced directly to users (`Wake backlog`, `Coalesce if active`, `Catch-up policy`, `Catch-up cap`, `Stale or tampered content hash`, `Filter by DID`).
4. **Inconsistent Action Verbs:** Varying verbs (`Hire Remote` vs `New Agent` vs `Create agent`) were used across different entry points.

This document serves as the authoritative, permanent audit log recording every user-facing copy change, its context, and the rationale behind each human-friendly replacement.

---

## 2. Editorial Principles for UI Humanization

Every microcopy refinement adheres to four core editorial principles:

| Principle | Anti-Pattern | Target Human-Friendly Pattern |
|---|---|---|
| **Collaborative Over Militaristic** | "CEO command lane", "Launch posture", "dossier", "command center" | "Executive Overview", "System Status", "Company Profile", "overview" |
| **Constructive Over Punitive** | "Return weak submissions", "kicked back by reviewer" | "Request revisions on incomplete work", "Changes requested by reviewer" |
| **Outcome Over Telemetry** | "Wake backlog", "coalesce if active", "catch-up policy" | "Pending Tasks", "Combine overlapping runs", "Missed run handling" |
| **Clarity Over Cryptic Acronyms** | "Filter by DID", "stale or tampered content hash" | "Filter by Agent ID", "content modified since last review" |

---

## 3. Comprehensive Domain-by-Domain Audit Catalog

### 3.1 Executive Dashboard (`dashboard_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `dashboard_live/index.html.heex:357` | `CEO command lane` | `Executive Overview` | Replaced military "command lane" jargon with standard executive overview language. |
| `dashboard_live_test.exs:843, 877` | `"surfaces launch-ready CEO command lane"` / `"CEO command lane"` | `"surfaces launch-ready executive overview"` / `"Executive Overview"` | Synchronized LiveView test assertions to verify the humanized title renders properly. |

---

### 3.2 System Operations & Task Queue (`operations_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `operations_live/index.html.heex:1619` | `<h2 ...>Wake Backlog</h2>` | `<h2 ...>Pending Tasks</h2>` | "Wake Backlog" exposes low-level OTP wakeup scheduler queuing. "Pending Tasks" describes what the user actually sees and manages. |
| `operations_live_test.exs:1945` | `assert html =~ "Wake Backlog"` | `assert html =~ "Pending Tasks"` | Synchronized ExUnit assertion in test suite. |

---

### 3.3 Review Queue & Quality Gates (`review_queue_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `review_queue_live/index.html.heex:12` | `Approve finished work, return weak submissions, and clear CTO spec review.` | `Approve finished work, request revisions on incomplete work, and clear CTO spec review.` | Softened punitive "weak submissions" phrasing to professional, collaborative revision requests. |
| `review_queue_live/index.html.heex:75` | `{length(@kicked_back)} kicked back` | `{length(@kicked_back)} changes requested` | Standardized on professional "changes requested" over casual/punitive "kicked back". |
| `review_queue_live/index.html.heex:418` | `Sent back for rework` | `Changes requested` | Aligned rework section heading with standard PR and review conventions. |
| `review_queue_live/index.html.heex:429` | `No issues currently kicked back.` | `No issues currently have changes requested.` | Clean, respectful empty state phrasing. |
| `review_queue_live/index.ex:185, 212, 227, 242, 257` | `eyebrow: "Review command"` | `eyebrow: "Review Overview"` | Replaced repetitive "command" eyebrow with contextual overview label. |
| `review_queue_live_test.exs:64` | `assert html =~ "Review command"` | `assert html =~ "Review Overview"` | Synchronized test assertion. |
| `review_queue_live_test.exs:211` | `assert html =~ "No issues currently kicked back."` | `assert html =~ "No issues currently have changes requested."` | Synchronized empty state assertion. |

---

### 3.4 Automated Routines & Scheduling Policies (`routine_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `routine_live/index.html.heex:52` | `Routine command` | `Automated Routines` | Replaced "command" with descriptive feature title. |
| `routine_live_test.exs:54` | `assert html =~ "Routine command"` | `assert html =~ "Automated Routines"` | Synchronized test assertion. |
| `routine_live/index.ex:366-367` | `Catch-up: ...` / `Cap ...` | `Missed runs: ...` / `Max ...` | Replaced internal scheduler terms with self-explanatory labels for missed schedule handling. |
| `routine_live/index.ex:500-501` | `Setup posture` / `Automation posture` | `Setup status` / `Automation status` | Replaced military "posture" with standard system "status". |
| `routine_live/edit.html.heex:114` & `new.html.heex:124` | `{"Coalesce if active", "coalesce_if_active"}` | `{"Combine overlapping runs", "coalesce_if_active"}` | Explains what the option actually does rather than using database/OS jargon "coalesce". Underlying value unchanged. |
| `routine_live/edit.html.heex:122` & `new.html.heex:132` | `label="Catch-up policy"` | `label="Missed run handling"` | Plain-English form input label for handling missed cron triggers. |
| `routine_live/edit.html.heex:129` & `new.html.heex:142` | `label="Catch-up cap"` | `label="Maximum missed runs"` | Clarifies the cap number limit for missed executions. |

---

### 3.5 Budgets & Spending Limits (`budget_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `budget_live/index.html.heex:73` | `Budget command` | `Budget Overview` | Replaced "command" eyebrow with clear contextual overview title. |
| `budget_live_test.exs:15, 200` | `assert html =~ "Budget command"` | `assert html =~ "Budget Overview"` | Synchronized test assertions across both empty and populated states. |
| `budget_live_test.exs:22` | `refute html =~ "Budget Overview"` | `refute html =~ "Budget command"` | Inverted negation to ensure obsolete "Budget command" never re-enters markup. |

---

### 3.6 Cost Analytics (`cost_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `cost_live/index.html.heex:88` | `Cost command` | `Cost Analytics` | Replaced "command" with industry-standard analytics naming. |
| `cost_live/index.ex:396` | `title: "Cost posture is clear for the next run"` | `title: "Cost status is clear for the next run"` | Replaced defense/tactical "posture" heading with standard system "status". |
| `cost_live_test.exs:8, 35, 55` | `describe "cost command"` / `assert html =~ "Cost command"` | `describe "cost analytics"` / `assert html =~ "Cost Analytics"` | Synchronized test describe block and assertions. |

---

### 3.7 Execution Policies (`execution_policy_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `execution_policy_live/index.html.heex:29` | `Policy command` | `Execution Policies` | Replaced "command" with explicit feature title. |
| `execution_policy_live/show.html.heex:4` | `Policy dossier` | `Policy Details` | Replaced espionage-themed "dossier" with clear, professional "Policy Details". |

---

### 3.8 Workspaces & Environments (`workspace_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `workspace_live/index.ex:72` | `Workspace command` | `Workspaces` | Replaced "command" with standard noun. |
| `workspace_live/show_workspace.ex:51, 55` | `project workspace command center` | `project workspace overview` | Softened pseudo-military "command center" in screen-reader and title attributes. |
| `workspace_live_test.exs:8, 25` | `test "...workspace command..."` / `assert html =~ "Workspace command"` | `test "...workspace overview..."` / `assert html =~ "Workspaces"` | Synchronized test description and assertion. |

---

### 3.9 Goals & OKRs (`goal_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `goal_live/index.html.heex:41` | `Goal command` | `Goals Overview` | Replaced "command" with intuitive overview heading. |
| `goal_live_test.exs:55, 101` | `assert html =~ "Goal command"` | `assert html =~ "Goals Overview"` | Synchronized ExUnit assertions across density modes. |

---

### 3.10 Company Profiles & Console (`company_live`, `company_export_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `company_live/show.html.heex:5` | `Company dossier` | `Company Profile` | Eliminated bureaucratic/espionage term "dossier". |
| `company_live/index.html.heex:93` | `Launch posture` | `System Status` | Replaced defense/tactical "posture" with standard "System Status". |
| `company_export_live.ex:133` | `Safety posture` | `Safety Status` | Replaced "posture" with "Status". |

---

### 3.11 Activity History (`activity_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `activity_live/index.html.heex:21` | `Activity command` | `Activity History` | Replaced "command" with warm, descriptive history label. |
| `activity_live/index.ex:217` | `change launch posture.` | `change system status.` | Replaced defense jargon in lane subtitle. |

---

### 3.12 Agents & Remote Marketplace (`agent_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `agent_live/remote.html.heex:61` | `placeholder="Search agents, DIDs, models, capabilities"` | `placeholder="Search agents, agent IDs, models, capabilities"` | Replaced obscure Web3 acronym "DIDs" (Decentralized Identifiers) with universal "agent IDs". |
| `agent_live/show.ex:2305` | `Remote agent DID` | `Remote Agent ID` | Clearer configuration item label. |
| `agent_live/index.html.heex:42` | `Hire Remote` | `Hire Remote Agent` | Aligned action button with target route `/agents/remote` page title ("Hire Remote Agent"). |
| `agent_live/index.html.heex:299` | `Create agent` | `Create Agent` | Standardized title-casing on primary empty-state CTA button. |
| `agent_live/show.html.heex:324, 328` | `id="agent-command-center"` / `Agent command` | `id="agent-overview"` / `Agent Overview` | Replaced pseudo-military "command center" and "command" eyebrow with standard "Agent Overview". |
| `agent_live_test.exs:494` | `assert html =~ "Agent command"` | `assert html =~ "Agent Overview"` / `assert html =~ "agent-overview"` | Synchronized LiveView agent detail assertions. |

---

### 3.13 Reusable Skills (`skill_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `skill_live/index.ex:247-248` | `Setup posture` / `Capability posture` | `Setup status` / `Capability status` | Humanized posture labels into clear status badges. |

---

### 3.14 Tool Traces & Audit Integrity (`tool_call_traces_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `tool_call_traces_live.ex:361` | `Trace sequence #{sequence} has a stale or tampered content hash. Inspect that row before using exports for audit or governance.` | `Trace sequence #{sequence} has content modified since last review. Inspect that row before using exports for audit or governance.` | Replaced hostile cryptographic error phrasing ("tampered content hash") with constructive explanation ("content modified since last review"). |
| `tool_call_traces_live_test.exs:185` | `assert html =~ "stale or tampered content hash"` | `assert html =~ "content modified since last review"` | Synchronized ExUnit test assertion. |

---

### 3.15 Issue Brief Readiness & Launch Verification (`issue_brief_readiness`, `issue_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `issue_brief_readiness.ex:194` | `Too thin for autonomy` | `Needs more detail` | Softened punitive readiness rejection into collaborative guidance for issue briefs. |
| `issue_live_test.exs:416, 534, 2828, 2829` | `assert html =~ "Too thin for autonomy"` | `assert html =~ "Needs more detail"` | Synchronized LiveView issue test assertions. |
| `operations_live_test.exs:438, 440` | `assert html =~ "Too thin for autonomy"` | `assert html =~ "Needs more detail"` | Synchronized operations CEO flow candidate readiness assertions. |
| `runtime_operations_test.exs:468, 487` | `assert brief =~ ... "Too thin for autonomy"` | `assert brief =~ ... "Needs more detail"` | Synchronized runtime operations snapshot and candidate brief assertions. |
| `agent_prompt_test.exs:284` | `assert ceo_prompt =~ "Too thin for autonomy"` | `assert ceo_prompt =~ "Needs more detail"` | Synchronized agent system prompt readiness string assertions. |

---

### 3.16 Extensible Plugins (`plugin_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `plugin_live/index.ex:309-310` | `Setup posture` / `Runtime posture` | `Setup status` / `Runtime status` | Standardized plugin health and posture labels to status badges (matching `skill_live` and `routine_live`). |

---

### 3.17 Runtime Secrets Management (`secrets_live`, `settings_hub`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `secrets_live/index.html.heex:63` | `Runtime credential cockpit` | `Runtime credentials` | Removed military/aviation "cockpit" jargon in favor of plain descriptive section label. |
| `secrets_live/index.html.heex:141` | `Rotation posture` | `Rotation status` | Replaced defense "posture" eyebrow with standard "Rotation status". |
| `settings_hub_test.exs:49, 78, 248` | `assert html =~ "Runtime credential cockpit"` / `"Rotation posture"` | `assert html =~ "Runtime credentials"` / `"Rotation status"` | Synchronized settings hub secrets tab assertions. |

---

### 3.18 Inbox & Action Queue (`inbox_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `inbox_live/index.html.heex:161` | `Inbox command` | `Inbox Overview` | Replaced military "command" eyebrow with clear contextual overview title. |
| `inbox_live_test.exs:28, 538` | `assert html =~ "Inbox command"` | `assert html =~ "Inbox Overview"` | Synchronized LiveView inbox assertions across default and filtered states. |

---

### 3.19 Projects & Workstreams (`project_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `project_live/show.html.heex:4` | `Project command` | `Project Overview` | Replaced "command" eyebrow with standard "Project Overview". |
| `project_live/show.html.heex:9, 12` | `project command center` | `project overview` | Replaced pseudo-military "command center" in screen-reader and title attributes. |
| `project_live/new.html.heex:32` | `Create the workstream command center` | `Create the workstream overview` | Humanized section heading for new project setup. |
| `project_live/new.html.heex:127` | `project command center` | `project overview` | Softened reference to project overview in onboarding setup step. |
| `project_live_test.exs:128` | `assert html =~ "Create the workstream command center"` | `assert html =~ "Create the workstream overview"` | Synchronized test assertion in new project creation suite. |
| `project_live_test.exs:275` | `assert html =~ "Project command"` | `assert html =~ "Project Overview"` | Synchronized test assertion in project detail view suite. |

---

### 3.20 Governance Audit Trail (`audit_trail_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `audit_trail_live/index.html.heex:22` | `Audit command` | `Audit Trail` | Replaced repetitive "command" label with standard "Audit Trail". |

---

### 3.21 Scoped Search (`search_live`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `search_live/index.html.heex:295` | `Search command` | `Search Overview` | Replaced "Search command" card eyebrow with intuitive "Search Overview". |
| `search_live_test.exs:14, 91` | `assert html =~ "Search command"` | `assert html =~ "Search Overview"` | Synchronized search test assertions across empty query and active result states. |

---

### 3.22 Session & Authentication (`session_controller`)

| Location | Original Microcopy | Human-Friendly Replacement | Context & Design Rationale |
|---|---|---|---|
| `session_controller.ex:171` | `company cockpit` | `company workspace` | Replaced aviation/military "cockpit" jargon with warm, collaborative "company workspace". |

---

## 4. Dual UI Mode Synchronization (`simple` vs `advanced`)

Cympho implements a dual-mode presentation architecture driven by client-side CSS and `data-ui-mode="simple" | "advanced"` attributes.
- **Simple Mode (`.ui-simple-only`)**: Keeps copy friendly, concise, and focused on immediate human action.
- **Advanced Mode (`.ui-advanced-only`)**: Presents deeper operational and technical context without degrading into cryptographic or military jargon.

Both versions are tested in lockstep via `test/cympho_web/live/simple_mode_copy_test.exs` and feature-level tests to ensure that simplifying advanced-mode microcopy never degrades or misaligns simple-mode guidance.

---

## 5. ExUnit Test Suite Synchronization Summary

All modified user-facing strings were updated alongside their corresponding ExUnit test assertions. The impacted test files include:
1. `test/cympho_web/live/dashboard_live_test.exs` — Verified `Executive Overview`.
2. `test/cympho_web/live/review_queue_live_test.exs` — Verified `Review Overview` and `No issues currently have changes requested.`
3. `test/cympho_web/live/operations_live_test.exs` — Verified `Pending Tasks` and `Needs more detail`.
4. `test/cympho_web/live/budget_live_test.exs` — Verified `Budget Overview`.
5. `test/cympho_web/live/cost_live_test.exs` — Verified `Cost Analytics`.
6. `test/cympho_web/live/routine_live_test.exs` — Verified `Automated Routines`.
7. `test/cympho_web/live/workspace_live_test.exs` — Verified `Workspaces`.
8. `test/cympho_web/live/goal_live_test.exs` — Verified `Goals Overview`.
9. `test/cympho_web/live/tool_call_traces_live_test.exs` — Verified `content modified since last review`.
10. `test/cympho_web/live/agent_live_test.exs` — Verified `Hire Remote Agent`, `Agent Overview`, and `agent-overview`.
11. `test/cympho_web/live/simple_mode_copy_test.exs` — Verified 100% pass across dual-mode assertions.
12. `test/cympho_web/live/issue_live_test.exs` — Verified `Needs more detail`.
13. `test/cympho/runtime_operations_test.exs` — Verified `Needs more detail`.
14. `test/cympho/agent_prompt_test.exs` — Verified `Needs more detail`.
15. `test/cympho_web/live/settings_hub_test.exs` — Verified `Runtime credentials` and `Rotation status`.
16. `test/mix/tasks/cympho_compare_test.exs` — Verified external OTLP tracing documentation check.
17. `test/cympho_web/live/inbox_live_test.exs` — Verified `Inbox Overview`.
18. `test/cympho_web/live/project_live_test.exs` — Verified `Project Overview` and `Create the workstream overview`.
19. `test/cympho_web/live/search_live_test.exs` — Verified `Search Overview`.

The entire test suite compiles cleanly without warnings and passes with 0 failures.
