# LLM-349 Structural Review — REJECTED

## Verdict: REJECTED — 5 Critical Structural Issues

The branch will crash at runtime. The feat commit only modified the template, not the backend LiveView.

---

## Issue 1: Missing Event Handlers (Runtime Crash)
**File:** `lib/cympho_web/live/issue_live/show.ex`

The template fires 8 events with no corresponding handlers:

| Event | Status |
|-------|--------|
| `start_editing` | MISSING |
| `save_title` | MISSING |
| `save_description` | MISSING |
| `cancel_editing` | MISSING |
| `update_priority` | MISSING |
| `assign_issue` | MISSING |
| `unassign_issue` | MISSING |
| `search_assignee` | MISSING |

The only status handler is `update_issue_status` (line 125), but the template calls `update_status`.

## Issue 2: Missing Helper Functions
**File:** `lib/cympho_web/live/issue_live/show.html.heex`

Template calls two functions that do not exist anywhere in the codebase:
- `valid_status_options(@issue.status)` — line 146
- `filtered_agents(@all_agents, @assignee_search)` — line 191

## Issue 3: Missing Socket Assigns
**File:** `lib/cympho_web/live/issue_live/show.ex`

Template references assigns never initialized in `mount`:
- `@editing` — controls inline edit visibility (lines 4, 10, 37, 43)
- `@assignee_search` — search input value (line 185)
- `@all_agents` — agent list for filtering (line 191)

## Issue 4: Wrong Event Name
**File:** `lib/cympho_web/live/issue_live/show.html.heex:141`

```html
<form phx-change="update_status">
```

Handler is `update_issue_status` at `show.ex:125`. Status changes go to a dead handler.

## Issue 5: Test Assertions Mismatch
**File:** `test/cympho_web/live/issue_live_test.exs`

Tests assert flash messages from handlers that don't exist:
- Line 115: `"Title updated"`
- Line 164: `"Description updated"`
- Line 186: `"Status updated to todo"`
- Line 228: `"Priority updated"`
- Line 266: `"Assignee updated"`

Tests pass for the wrong reason (no flash set, no error thrown).

---

## Root Cause

Commit `23dd582` ("feat(issues): add inline edit, status dropdown, assignee picker to issue detail") only modified `show.html.heex`. The LiveView backend `show.ex` was never updated.

## Required Fixes

1. Add all 8 missing `handle_event` callbacks to `show.ex`
2. Add `valid_status_options/1` and `filtered_agents/2` helper functions
3. Initialize `@editing`, `@assignee_search`, `@all_agents` in `mount`
4. Fix `phx-change="update_status"` → `phx-change="update_issue_status"`
5. Align test assertions with actual flash message behavior
