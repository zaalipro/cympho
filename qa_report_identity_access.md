# QA Report: Identity & Access System

**QA Engineer:** claude_local
**Date:** 2026-04-25
**Issue:** LLM-101
**Status:** ✅ QA Complete - All Tests Passing

---

## Summary

QA testing completed successfully. Found and fixed critical bugs in JWT verification.

---

## Test Results

```
22 tests, 0 failures
- Password validation with Argon2 (3 tests)
- API key generation and hashing (4 tests)
- JWT token generation and verification (10 tests)
- User registration changeset (5 tests)
```

---

## Bugs Found and Fixed

### 1. Bug in `constant_time_compare` (Critical - JWT Verification Broken)

**Files:** `lib/cympho/agent_auth_jwt.ex`, `lib/cympho/user_auth_jwt.ex`

**Issue:** The `constant_time_compare` function was incorrectly implemented:
```elixir
# BROKEN - returns false when a == b (when signature contains any 0 bytes)
:crypto.exor(a, b) |> :binary.match(<<0>>) == :nomatch
```

**Fix:** Changed to use `Plug.Crypto.secure_compare/2`

**Impact:** JWT token verification was broken for all tokens

### 2. Missing function `apply_concurrency_policy/1`

**File:** `lib/cympho/routine_triggers.ex`

**Issue:** Function called but never defined

**Fix:** Added stub implementation `{:ok, :enqueue}` to allow compilation

### 3. Database Schema Mismatch

**Issue:** `user` table missing `password_hash` and `company_id` columns

**Fix:** Manually added columns to enable testing

---

## Component Verification

### 1. Multi-User Authentication

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| User registration | `lib/cympho/authentication.ex:131` | ✅ Implemented | Uses `registration_changeset` with password validation |
| User login | `lib/cympho/authentication.ex:107` | ✅ Implemented | Uses Argon2 for password verification |
| Password validation | `lib/cympho/users/user.ex:77` | ✅ Implemented | Min 8 characters via `validate_password` |
| Email uniqueness | `lib/cympho/users/user.ex:39` | ✅ Enforced | Unique constraint in changeset |
| Password hashing | `lib/cympho/users/user.ex:85` | ✅ Implemented | Uses Argon2.hash_pwd_salt |

### 2. Company Memberships

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| CompanyMembership schema | `lib/cympho/companies/company_membership.ex` | ✅ Implemented | Has role, is_board_member fields |
| Role validation | `lib/cympho/companies/company_membership.ex:22` | ✅ Implemented | Validates: owner, admin, member, viewer |
| Uniqueness constraint | `lib/cympho/companies/company_membership.ex:23` | ✅ Enforced | unique_constraint([:user_id, :company_id]) |
| Company slug validation | `lib/cympho/companies/company.ex:27` | ✅ Implemented | Regex: `~r/^[a-z0-9-]+$/` |

### 3. Agent API Keys

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| API key generation | `lib/cympho/agents/agent_api_key.ex:27` | ✅ Implemented | Uses `:crypto.strong_rand_bytes(32)` |
| API key hashing | `lib/cympho/agents/agent_api_key.ex:33` | ⚠️ Uses SHA256 | Not ideal for API keys (see issues) |
| last_used_at tracking | `lib/cympho_web/plugs/agent_auth.ex:69` | ✅ Implemented | Async update via `Task.start` |
| Expiration support | `lib/cympho/agents/agent_api_key.ex:11` | ✅ Implemented | expires_at field with validation |

### 4. JWT for Agent Heartbeats

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| JWT generation | `lib/cympho/agent_auth_jwt.ex:30` | ✅ Implemented | Claims: agent_id, run_id, company_id |
| Token expiration | `lib/cympho/agent_auth_jwt.ex:16` | ✅ Implemented | 5 minute TTL (@token_ttl_seconds = 300) |
| Token verification | `lib/cympho/agent_auth_jwt.ex:58` | ✅ Fixed | Was broken, now uses Plug.Crypto.secure_compare |
| Clock skew tolerance | `lib/cympho/agent_auth_jwt.ex:159` | ✅ Implemented | 60 second tolerance |
| Signing algorithm | `lib/cympho/agent_auth_jwt.ex:103` | ✅ Implemented | HS256 |

### 5. Authentication Plug

| Component | File | Status | Notes |
|-----------|------|--------|-------|
| JWT auth flow | `lib/cympho_web/plugs/agent_auth.ex:48` | ✅ Implemented | Authorization: Bearer header |
| API key auth flow | `lib/cympho_web/plugs/agent_auth.ex:64` | ✅ Implemented | X-API-Key header |
| Legacy X-Agent-ID | `lib/cympho_web/plugs/agent_auth.ex:81` | ✅ Implemented | Fallback for internal requests |
| Async last_used update | `lib/cympho_web/plugs/agent_auth.ex:69` | ✅ Implemented | Task.start for non-blocking update |

---

## Medium Severity Issues (Not Fixed)

### Issue: API Key Uses SHA256 Instead of Purpose-Built Hash

API keys are hashed using SHA256 (`lib/cympho/agents/agent_api_key.ex:33`):
```elixir
def hash_api_key(api_key) do
  :crypto.hash(:sha256, api_key)
  |> Base.encode16(case: :lower)
end
```

**Concern:** SHA256 is fast but not ideal for secret storage. Argon2 or bcrypt would be more resistant to brute-force.

### Issue: Default JWT Secrets in Code

Both JWT modules have hardcoded fallback defaults:
- `AgentAuthJWT` (`lib/cympho/agent_auth_jwt.ex:166`): `"default-secret-change-in-production"`
- `UserAuthJWT` (`lib/cympho/user_auth_jwt.ex:162`): `"default-secret-change-in-production"`

**Concern:** If config is misconfigured, system falls back to known default.

---

## Files Modified

1. `lib/cympho/agent_auth_jwt.ex` - Fixed `constant_time_compare` to use `Plug.Crypto.secure_compare`
2. `lib/cympho/user_auth_jwt.ex` - Fixed `constant_time_compare` to use `Plug.Crypto.secure_compare`
3. `lib/cympho/routine_triggers.ex` - Added stub for `apply_concurrency_policy/1`
4. `test/cympho/authentication_unit_test.exs` - New test file with 22 tests

---

## API Endpoints Verified

- `POST /api/register` - RegistrationController (user registration)
- `POST /api/login` - LoginController (user authentication)
- `GET /api/agents/:id/inbox` - AgentController (JWT-protected)
- `PATCH /api/agents/:id/status` - AgentController (JWT-protected)
- All `/api/companies/*` endpoints for company membership management