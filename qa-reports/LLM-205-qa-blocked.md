# QA Report: LLM-205 — Budget and Company Config Approval Workflows

**QA Health: BLOCKED**

**Date:** 2026-04-25
**Commit verified:** cd87a78 (exists on origin/main)
**Test file:** test/cympho/budget_company_approval_workflow_test.exs

---

## Verification Status

- Remote commit verified: `cd87a78` exists on `origin/main`
- Test file confirmed on main with comprehensive coverage
- **Tests cannot run due to workspace compilation errors**

---

## Blocker

The workspace contains uncommitted files causing compilation errors:

```
** (CompileError) lib/cympho_web/controllers/preview_controller.ex: undefined function put_resp_headers/2
** (CompileError) lib/cympho_web/controllers/preview_controller.ex: undefined function send_resp/2
```

### Untracked files present in workspace:
- `lib/cympho_web/controllers/preview_controller.ex`
- `lib/cympho_web/live/company_export_live.ex`
- `lib/cympho/workspaces/preview_url.ex`

### Modified files:
- `lib/cympho/workspaces.ex`
- `lib/cympho_web/live/company_live/show.html.heex`
- `lib/cympho_web/live/workspace_live/exec_workspace.ex`
- `lib/cympho_web/router.ex`

---

## Test Coverage Review (from main)

The test file on main covers all required scenarios:

1. **Budget creation above threshold** - Returns `{:pending_approval, approval}`
2. **Budget creation below threshold** - Succeeds directly
3. **Budget update increasing limit** - Returns `{:pending_approval, approval}`
4. **Budget update decreasing limit** - Succeeds directly
5. **Company governance_config change** - Returns `{:pending_approval, approval}`
6. **Company name change** - Succeeds directly even with governance
7. **Board approval vote auto-approve** - Threshold met triggers auto-approve
8. **Approved budget_increase** - Creates/updates budget
9. **Approved policy_change** - Updates company config
10. **Edge cases** - No company_id bypasses governance, invalid attrs return changeset errors, audit logs created

---

## Required Action

Engineer must either:
1. Commit the preview_controller.ex changes that define `put_resp_headers/2` and `send_resp/2`, OR
2. Remove the untracked files if they are not part of LLM-136

Tests will be re-run once the compilation issue is resolved.

---

## Test Execution Command

```bash
source /home/deploy/.asdf/asdf.sh
mix test test/cympho/budget_company_approval_workflow_test.exs
```