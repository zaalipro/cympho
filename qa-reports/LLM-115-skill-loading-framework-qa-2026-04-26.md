# LLM-115 QA Report: Skill Loading Framework (QA Engineer - claude_local)
**Date:** 2026-04-26
**Status:** BLOCKED
**Branch:** LLM-106d/rate-limiting (missing fix commit 4c25661 from main)

## Executive Summary

QA validation was triggered by `issue_blockers_resolved` but **cannot proceed** because:
1. Fix commit `4c25661` (3 trust boundary fixes) exists on `main` but NOT on current branch
2. Test file `hot_reloader_test.exs` has pre-existing compilation errors blocking test execution
3. Framework has significant implementation gaps

---

## Blocker: Branch Mismatch

The fix commit `4c25661` ("LLM-104: Fix 3 trust boundary violations in skill loading") is on `main` but current branch `LLM-106d/rate-limiting` hasn't merged it.

**Missing fixes on current branch:**
| Issue | File | Line | Status |
|-------|------|------|--------|
| Trust boundary: `fetch_agent_skills/1` missing `company_id` filter | resolver.ex | 115-127 | **UNFIXED** |
| Trust boundary: `HotReloader` uses first company pattern | hot_reloader.ex | 219-229 | **UNFIXED** |
| Runtime: `Mix.env()` compile-time fallback | hot_reloader.ex | 143-145 | **UNFIXED** |

---

## Test File Compilation Error

```
== Compilation error in file test/cympho/skills/hot_reloader_test.exs ==
** (UndefinedFunctionError) function File.join/2 is undefined or private
    test/cympho/skills/hot_reloader_test.exs:9: (module)
```

`File.join/2` does not exist in Elixir — should be `Path.join/2`. Also `company_id_for_test/0` function definition may be outside module scope.

---

## Framework Implementation Status

### Module: `Cympho.Skills.Resolver`
- [x] GenServer with ETS cache (`:cympho_skill_resolver_cache`)
- [x] `resolve/2` (with explicit company_id) — signature exists but company filtering UNTESTED
- [x] `resolve/1` (deprecated, logs warning)
- [x] Cycle detection via DFS
- [x] Semver compatibility checking
- [ ] **TC-3 FAILS**: `available_skills` not integrated into AgentHeartbeat
- [ ] **TC-4 FAILS**: `build_prompt/1` doesn't include skill metadata

### Module: `Cympho.Skills.Loader`
- [x] GenServer with ETS cache (`:cympho_skill_loader_cache`)
- [x] `validate_manifest/1`
- [x] `load/1`, `unload/1`, `loaded?/1`, `get_manifest/1`
- [ ] **NOT IMPLEMENTED**: Actual skill code loading (only validates entrypoint exists)
- [ ] **TC-6 FAILS**: Sandbox not enforced

### Module: `Cympho.Skills.HotReloader`
- [x] GenServer with 2-second debounce
- [x] FileSystem watcher in dev
- [ ] **NOT IMPLEMENTED**: Proper company derivation from manifest file path
- [ ] **NOT IMPLEMENTED**: `Application.get_env(:cympho, :env)` only (no Mix.env fallback)

### Not Yet Implemented
- [ ] **TC-7**: Cycle detection — resolver has it but no end-to-end test
- [ ] **TC-8**: Hot-reload verification within 2 seconds — no test harness
- [ ] **Sandbox enforcement**: `capabilities` field never enforced
- [ ] **TC-5 Regression**: PASS (no skill dependencies in existing code)

---

## Test Cases

| ID | Test Case | Status | Finding |
|----|-----------|--------|---------|
| TC-1 | Register skill in plugins table | PARTIAL | Schema exists, runtime untested |
| TC-2 | Assign skill to agent | PARTIAL | Join table exists, no assignment functions |
| TC-3 | available_skills in heartbeat | **FAIL** | Missing integration in AgentHeartbeat |
| TC-4 | Skill metadata in prompt | **FAIL** | build_prompt/1 only has issue info |
| TC-5 | Skill-less agents regression | PASS | No skill dependencies in existing agents |
| TC-6 | Sandbox capability enforcement | **FAIL** | `capabilities` field never checked |
| TC-7 | Cycle detection | **NOT IMPLEMENTED** | Resolver has logic, no integration test |
| TC-8 | Hot-reload < 2s | **NOT IMPLEMENTED** | No test harness |

---

## Recommendations

1. **Immediate**: Merge `main` into `LLM-106d/rate-limiting` to bring in trust boundary fixes
2. **Immediate**: Fix `hot_reloader_test.exs` compilation error (use `Path.join/2`)
3. **Before QA can proceed**: Framework must be integrated into AgentHeartbeat and build_prompt
4. **Before TC-6/7/8 pass**: Sandbox, cycle detection, and hot-reload test harness must be implemented

---

## QA Engineer Notes

- Issue marked `in_progress` by liveness continuation, but **BLOCKED by branch mismatch**
- Cannot run full test suite due to test file compilation error
- Cannot validate TC-3/TC-4 without framework integration into agent runtime
- This issue should remain BLOCKED until: (1) current branch has fix commit, (2) integration is complete, (3) test file compiles