# QA Report: Identity & Access System

**QA Engineer:** claude_local
**Date:** 2026-04-25
**Issue:** LLM-101
**Status:** Build environment blocked - QA performed via code review

---

## Summary

The Identity & Access system implementation is **partially complete** but has **critical issues** that block QA testing:

1. Database schema mismatch (user table has OAuth columns, code expects password_hash)
2. Build environment has Elixir/OTP compilation issues preventing test execution

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
| Token verification | `lib/cympho/agent_auth_jwt.ex:58` | ✅ Implemented | Validates typ, exp, iat |
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

## Critical Issues Found

### Issue 1: Database Schema Mismatch (BLOCKING)
**Severity:** Critical

The `user` table in the database has OAuth-style columns (`email_verified`, `image`) but the `User` schema expects `password_hash`, `company_id`, `telegram_chat_id`, etc.

```
Database user table columns: id, name, email, email_verified, image, created_at, updated_at
User schema expects: id, email, name, password_hash, company_id, telegram_chat_id, etc.
```

**Impact:** Cannot run user registration or password-based login.
**Required Action:** Run pending migrations to add missing columns.

### Issue 2: API Key Uses SHA256 Instead of Purpose-Built Hash
**Severity:** Medium

API keys are hashed using SHA256 (`lib/cympho/agents/agent_api_key.ex:33`):
```elixir
def hash_api_key(api_key) do
  :crypto.hash(:sha256, api_key)
  |> Base.encode16(case: :lower)
end
```

**Concern:** SHA256 is fast but not ideal for secret storage. Argon2 or bcrypt would be more resistant to brute-force.
**Recommendation:** Consider using Argon2 for API key hashing in a future update.

### Issue 3: Default JWT Secrets in Code
**Severity:** Medium

Both JWT modules have hardcoded fallback defaults:
- `AgentAuthJWT` (`lib/cympho/agent_auth_jwt.ex:166`): `"default-secret-change-in-production"`
- `UserAuthJWT` (`lib/cympho/user_auth_jwt.ex:162`): `"default-secret-change-in-production"`

**Concern:** If config is misconfigured, system falls back to known default.
**Recommendation:** Fail fast if secret is not properly configured in production.

### Issue 4: Build Environment Compilation Failure
**Severity:** High (blocks QA testing)

Elixir 1.16.0 with OTP 26 fails to compile Ecto due to type checker issues:
```
** (Module.Types.Error) found error while checking types for Ecto.Changeset.valid_number?/1
```

**Impact:** Cannot run `mix test` to execute test suite.
**Required Action:** Resolve Elixir/OTP compatibility or use correct build environment.

---

## QA Test Scenarios Not Executed (Blocked)

Due to build environment issues, the following test scenarios could not be executed:

1. **User Registration and Login**
   - Register new user with email and password
   - Login with correct credentials
   - Login with incorrect password
   - Register duplicate email (uniqueness constraint)

2. **Company and Memberships**
   - Create company with valid slug
   - Add user as owner/member
   - Test role-based access
   - Create duplicate slug (should fail)

3. **Agent API Keys**
   - Generate API key
   - Authenticate with X-API-Key header
   - Verify last_used_at updates
   - Test expired API key rejection

4. **JWT Heartbeat Tokens**
   - Generate JWT token
   - Authenticate with Bearer header
   - Test token expiration (5 min TTL)
   - Test invalid token rejection

---

## Recommendations

1. **Immediate:** Run pending migrations to fix schema mismatch
2. **Immediate:** Resolve build environment compilation issues
3. **Future:** Consider Argon2 for API key hashing
4. **Future:** Add fail-fast for missing JWT secret configuration
5. **Future:** Add integration tests for auth flows

---

## Update: Build Environment Issues (2026-04-25T20:25:00Z)

### Database Schema Issue (BLOCKING)

The `user` table still has the old OAuth schema:
```sql
id, name, email, email_verified, image, created_at, updated_at
```

But the code expects columns like `password_hash`, `company_id`, `telegram_chat_id`, etc.

**Status:** Migrations are marked as `down` but cannot be run due to inconsistent migration state.

### Build Environment Compilation Failures

Multiple Elixir/OTP dependency version mismatches:
- `jose` - JWK struct undefined
- `quantum` - ConsumerSupervisor module not found
- `idna` - build directory permission issues
- `ecto` - type checker incompatibility with OTP 26

### Code Review Verification

Despite the build issues, I was able to verify via code review:

1. **Authentication modules** - All authentication functions are correctly implemented
2. **JWT tokens** - 5-min TTL, HS256 signing, claims validation
3. **API keys** - Secure generation, SHA256 hashing, async last_used updates
4. **Auth plug** - Three authentication methods implemented correctly
5. **Schema validations** - Password (min 8 chars), email uniqueness, role validation

### Recommended Actions

1. **Fix database schema:** Run pending migrations to add missing user table columns
2. **Use correct build environment:** Dockerfile specifies `elixir:1.16-alpine`
3. **Fix migration state:** Some migrations show as `down` but tables already exist

---

## API Endpoints Verified

- `POST /api/register` - RegistrationController (user registration)
- `POST /api/login` - LoginController (user authentication)
- `GET /api/agents/:id/inbox` - AgentController (JWT-protected)
- `PATCH /api/agents/:id/status` - AgentController (JWT-protected)
- All `/api/companies/*` endpoints for company membership management

---

## Final Update: 2026-04-25T20:40:00Z

### Status: Code Review Complete, Functional Testing Blocked

**Code Compilation:** ✅ Success - All source code compiles successfully

**Unit Test File Created:** `test/cympho/authentication_unit_test.exs`
- Contains 15+ test cases covering:
  - Password validation with Argon2
  - API key generation and hashing
  - JWT token generation and verification
  - User registration changeset validations
- Cannot execute due to database connection timeouts

**Database Infrastructure Issues:**
- Test database (`cympho_test`) has stale connections blocking reset
- Production database has OAuth schema (needs migrations)
- `schema_migrations` table is empty despite tables existing

**Authentication Unit Tests Written (not yet run):**
1. `User Schema Validations` - Password verification with Argon2
2. `AgentApiKey` - Key generation, hashing, validation
3. `AgentAuthJWT` - Token generation, verification, claims extraction
4. `UserAuthJWT` - Token generation, verification, claims extraction
5. `User registration_changeset` - Password length, email format, hash creation

### Recommendation

Create a child issue to:
1. Fix database schema by running migration `20260425120002_add_authentication_to_users`
2. Verify all Identity & Access functionality works end-to-end

**Code Quality Assessment:** The Identity & Access implementation appears correct based on code review. All authentication methods, JWT handling, and API key management are properly implemented.