# QA Report: LLM-101 Identity & Access System

**QA Engineer:** Agent 8eb4b450-79e4-4cb2-8e20-25723fde6f15
**Date:** 2026-04-25
**Commit SHA:** 35bef1dc61868622b3ad11310d541df90140a21a
**Branch:** main
**Testing Mode:** Code Review + Static Analysis

---

## Health Score: ❌ FAIL

**Critical Blockers Found: 1**

---

## Executive Summary

The Identity & Access system implementation has a **critical wiring issue**: user registration with password authentication is implemented but **not exposed via any API endpoint**. The `Authentication.register_user/1` function exists but has no route, making multi-user authentication impossible to test through the API.

**Recommendation:** Do not merge until the registration endpoint is properly wired.

---

## Test Results by Feature Area

### 1. Multi-user Authentication ❌

#### User Registration (BLOCKED - No API Endpoint)

| Test | Status | Notes |
|------|--------|-------|
| Register user with valid password | **BLOCKED** | No API endpoint exists |
| Email uniqueness constraint | Unverified | No endpoint to test |
| Password validation (min 8 chars) | Code Review OK | `validate_password/1` enforces min 8 |

**Finding:** `Authentication.register_user/1` exists (`lib/cympho/authentication.ex:132-136`) but is **not connected to any route**.

**Root Cause:**
- `POST /api/users` routes to `UserController.create`
- `UserController.create` calls `Users.create_user(user_params)`
- `Users.create_user` uses `User.changeset` (line 62 in `lib/cympho/users.ex`)
- `User.changeset` does NOT process password field
- `User.registration_changeset` (which handles password with Argon2 hashing) is never called

**Affected Code Path:**
```
lib/cympho_web/router.ex:55 → resources "/users"
lib/cympho_web/controllers/user_controller.ex:14 → def create
lib/cympho/users.ex:60 → create_user
lib/cympho/users/user.ex:25 → changeset (NOT registration_changeset)
```

#### User Login

| Test | Status | Notes |
|------|--------|-------|
| Login with correct credentials | **BLOCKED** | No login endpoint exists |
| Login with incorrect password | **BLOCKED** | No login endpoint exists |

**Finding:** No login/authentication endpoint exists in the router.

---

### 2. Company Memberships ⚠️ PARTIAL

| Test | Status | Notes |
|------|--------|-------|
| Create company with valid slug | Code Review OK | `Companies.create_company/1` exists |
| Company slug validation | Code Review OK | Regex `^[a-z0-9-]+$`, length 3-50 |
| Add users with roles | Code Review OK | `create_membership/1` exists |
| Role-based access control | **NO API** | No membership endpoints |
| Membership uniqueness | Code Review OK | `unique_constraint([:user_id, :company_id])` |

**Finding:** Companies and memberships contexts exist but **no API routes** are defined.

---

### 3. Agent API Keys ✅ CODE REVIEW PASS

| Test | Status | Location |
|------|--------|----------|
| API key generation | Code Review OK | `lib/cympho/agents/agent_api_key.ex:27-31` |
| API key hashing (SHA-256) | Code Review OK | `lib/cympho/agents/agent_api_key.ex:33-36` |
| Key storage (hash only) | Code Review OK | Plain text never stored |
| Expiration support | Code Review OK | `expires_at` field, checked in plug |
| Last used tracking | Code Review OK | `last_used_at` updated async in plug |

**Implementation Quality:** Strong - uses crypto.strong_rand_bytes for key generation, SHA-256 hashing, proper async update of last_used_at.

---

### 4. JWT for Agent Heartbeats ✅ CODE REVIEW PASS

| Test | Status | Location |
|------|--------|----------|
| JWT generation | Code Review OK | `lib/cympho/agent_auth_jwt.ex:30-46` |
| Claims include agent_id, run_id, company_id | Code Review OK | Lines 34-36 |
| 5-minute TTL | Code Review OK | `@token_ttl_seconds 300` (line 16) |
| Token expiration validation | Code Review OK | `validate_expiration/1` (line 148-152) |
| Token type validation | Code Review OK | `typ => "agent_heartbeat"` enforced |
| Iat (issued at) validation | Code Review OK | Allows 60s clock skew |
| Signature verification | Code Review OK | HMAC-SHA256 with constant-time compare |

**Implementation Quality:** Solid - proper JWT structure, exp/iat claims, type validation, signature verification with constant-time comparison.

---

### 5. Authentication Plug ⚠️ PARTIAL

| Test | Status | Notes |
|------|--------|-------|
| JWT via Bearer header | Code Review OK | `authenticate_with_jwt/1` |
| API Key via X-API-Key header | Code Review OK | `authenticate_with_api_key/1` |
| Legacy X-Agent-ID fallback | Code Review OK | `authenticate_with_agent_id/1` |
| Expired API key rejection | Code Review OK | Line 104 checks `expires_at` |
| Invalid token rejection | Code Review OK | Proper error handling |

**Applied To:** Routes under `scope "/api"` with `pipe_through [:api, CymphoWeb.Plugs.AgentAuth]` (router.ex:101-112)

**Finding:** Plug is correctly implemented but **only protects agent endpoints**, not user authentication endpoints.

---

## Critical Bug: Registration Not Wired

### Issue

```elixir
# lib/cympho/authentication.ex:132-136
def register_user(attrs) do
  %Cympho.Users.User{}
  |> Cympho.Users.User.registration_changeset(attrs)  # Handles password!
  |> Repo.insert()
end
```

This function exists but is **never called from any controller or route**.

### Current Broken Path

```elixir
# lib/cympho_web/controllers/user_controller.ex:14-19
def create(conn, %{"user" => user_params}) do
  with {:ok, %User{} = user} <- Users.create_user(user_params) do
    # Uses User.changeset, NOT registration_changeset - password ignored!
```

### Fix Required

Either:
1. Add a registration endpoint (`POST /api/register`) that calls `Authentication.register_user/1`, OR
2. Modify `UserController.create` to use `registration_changeset` when password is present

---

## Verification Protocol Compliance

| Step | Status |
|------|--------|
| Fetch canonical remote | ⚠️ Failed (no credentials for github.com) |
| Verify branch exists | ✅ Commit 35bef1dc exists locally |
| Read actual remote files | ✅ Read from local HEAD |
| Count handlers/lines | ✅ Verified all key files |

**Note:** Could not run `mix test` - Elixir/Mix not available in environment.

---

## Summary

**Cannot approve for merge.** The user registration feature is implemented but not accessible via any API endpoint, making the entire multi-user authentication system untestable and unusable.

**Required Action:** Wire `Authentication.register_user/1` to an API endpoint before this can pass QA.

---

## Files Reviewed

| File | SHA Verified |
|------|-------------|
| `lib/cympho/agent_auth_jwt.ex` | 35bef1dc |
| `lib/cympho/authentication.ex` | 35bef1dc |
| `lib/cympho/users/user.ex` | 35bef1dc |
| `lib/cympho/companies/company.ex` | 35bef1dc |
| `lib/cympho/companies/company_membership.ex` | 35bef1dc |
| `lib/cympho/agents/agent_api_key.ex` | 35bef1dc |
| `lib/cympho_web/plugs/agent_auth.ex` | 35bef1dc |
| `lib/cympho_web/router.ex` | 35bef1dc |
| `lib/cympho_web/controllers/user_controller.ex` | 35bef1dc |
| `lib/cympho/users.ex` | 35bef1dc |
| `lib/cympho/companies.ex` | 35bef1dc |

---

## Continuation Notes (2026-04-25T17:30 UTC)

QA run completed. Critical blocker identified prevents full QA testing.

### Next Steps to Unblock Full QA

1. **Fix Registration Wiring** - Add `POST /api/register` endpoint or modify `UserController.create` to use `registration_changeset` when password present
2. **Add Login Endpoint** - `POST /api/login` that calls `Authentication.authenticate_user/2`
3. **Add Company Membership Endpoints** - CRUD routes for `/api/companies` and `/api/companies/:id/memberships`
4. **Re-run QA** after fixes are implemented

### QA Status

- Issue LLM-101 status: `in_progress` (awaiting implementation fixes)
- QA report posted to issue comments
- Cannot mark QA complete until blocker is resolved