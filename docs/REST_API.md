# REST API Reference

Cympho exposes a comprehensive JSON REST API for user interfaces, automation scripts, external CI/CD pipelines, and headless integrations.

---

## 1. General Conventions & Authentication

### 1.1 Base URL & Content Type
- **Base URL**: `http://localhost:4329/api` (development) or `https://cympho.llmotions.com/api` (production)
- **Content-Type**: `application/json`
- **Accept**: `application/json`

### 1.2 Authentication Methods

#### 1. User Bearer Token (JWT)
Most REST endpoints require user authentication:
```http
Authorization: Bearer <user_jwt_token>
```
Obtain this token via `POST /api/login` or `POST /api/register`.

#### 2. Agent Token / API Key
Endpoints in the agent scope (`/api/agents/*`, `/api/issues/:id/attachments`, `/api/mcp/*`) accept:
```http
Authorization: Bearer <agent_jwt_token>
```
or
```http
X-API-Key: <agent_api_key>
```

#### 3. Webhook Authentication
Inbound webhooks use specific signing methods:
- Routine triggers (`/api/routine-triggers/:public_id/fire`): HMAC-SHA256 signature (`x-cympho-signature`, `x-cympho-timestamp`) or legacy bearer (`x-webhook-secret`).
- GitHub webhooks (`/api/github/webhook`): GitHub HMAC signature (`X-Hub-Signature-256`).

### 1.3 Multi-Tenant Company Scoping
Cympho enforces strict multi-tenancy. For user endpoints, the active company is resolved in the following priority order:
1. `x-company-id: <company_uuid>` request header
2. `company_id` claim in the user JWT
3. User's default `company_id`
4. First active company membership for the user

If the user is not an active member of the resolved company, the API returns **HTTP 403 Forbidden**.

### 1.4 Standard Error Response Format
All errors return consistent JSON payloads:
```json
{
  "errors": [
    {
      "detail": "Description of the failure"
    }
  ]
}
```
Or for validation errors on changesets:
```json
{
  "errors": {
    "title": ["can't be blank"],
    "priority": ["is invalid"]
  }
}
```

---

## 2. Authentication & Account APIs

### 2.1 User Login
`POST /api/login` (Public)

Authenticates user credentials and returns a signed user JWT token with company scoping.

#### Request Body
```json
{
  "user": {
    "email": "owner@cympho.local",
    "password": "password1234"
  }
}
```

#### Response (HTTP 200)
```json
{
  "data": {
    "id": "1e7cb801-b3b3-467b-99f2-ff6b42b78119",
    "email": "owner@cympho.local",
    "name": "Company Owner",
    "company_id": "8bbbb9a8-e161-460d-8889-131db2fc3796"
  },
  "token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9..."
}
```

---

### 2.2 User Registration
`POST /api/register` (Public)

Registers a new user account. When open registration is disabled, a valid invitation token is required.

#### Request Body
```json
{
  "user": {
    "email": "engineer@cympho.local",
    "password": "strongPassword1234!",
    "name": "Lead Engineer"
  },
  "invite_token": "inv_9b83bfa0921c"
}
```

#### Response (HTTP 201)
```json
{
  "data": {
    "id": "2d9ab802-c1c1-477c-aa92-ee5b32a67220",
    "email": "engineer@cympho.local",
    "name": "Lead Engineer"
  }
}
```

---

### 2.3 Accept Company Invitation
`POST /api/invites/:token/accept` (Authenticated)

Accepts an invitation to join an existing company.

---

## 3. Issues & Tasks API

All issue endpoints require `Authorization: Bearer <user_jwt_token>` and are scoped to the current company.

### 3.1 Create Issue
`POST /api/issues`

Creates a new issue/task in the current company.

#### Request Body
```json
{
  "issue": {
    "title": "Migrate database pool to Ecto 3.12",
    "description": "Upgrade database pool configurations and verify transaction leak fixes.",
    "priority": "high",
    "status": "todo",
    "project_id": "3c983c21-f81d-4008-8e6f-fb94e1d1f054",
    "assigned_role": "engineer",
    "assignee_id": "c1f7a61d-3bb3-4c90-93dc-8a716c5222ef"
  }
}
```

#### Supported Issue Fields
- `title` (required, string)
- `description` (optional, string)
- `status` (`backlog`, `todo`, `in_progress`, `in_review`, `done`, `blocked`, `cancelled`)
- `priority` (`critical`, `high`, `medium`, `low`)
- `project_id` (UUID)
- `goal_id` (UUID)
- `parent_id` (UUID)
- `assignee_id` (UUID of agent)
- `assignee_user_id` (UUID of human user)
- `assigned_role` (`ceo`, `cto`, `engineer`, `product_manager`, `designer`, `qa_engineer`, etc.)
- `execution_policy_id` (UUID)
- `work_mode` (`standard`, `planning`, `ask`)
- `billing_code` (string)
- `due_on` (date)
- `github_pr_url` (URL string)
- `github_pr_number` (integer)

#### Response (HTTP 201)
```json
{
  "data": {
    "id": "e2275eb1-344c-43f1-b94d-2a13ccfc0298",
    "title": "Migrate database pool to Ecto 3.12",
    "description": "Upgrade database pool configurations...",
    "status": "todo",
    "priority": "high",
    "project_id": "3c983c21-f81d-4008-8e6f-fb94e1d1f054",
    "assignee_id": "c1f7a61d-3bb3-4c90-93dc-8a716c5222ef",
    "inserted_at": "2026-10-15T08:30:00Z",
    "updated_at": "2026-10-15T08:30:00Z"
  }
}
```

---

### 3.2 Get Issue Detail
`GET /api/issues/:id`

Retrieves an issue by ID within the authenticated company.

---

### 3.3 Manage Issue Labels
- `GET /api/issues/:issue_id/labels`: List all labels attached to an issue.
- `POST /api/issues/:issue_id/labels`: Add a label by `{"label_id": "<uuid>"}`.
- `DELETE /api/issues/:issue_id/labels/:label_id`: Remove a label.
- `PUT /api/issues/:issue_id/labels`: Replace all labels with `{"label_ids": ["<uuid>", ...]}`.

---

### 3.4 Issue Read State & Attention
- `GET /api/issues/:issue_id/read-state`: Check whether current user/agent has read the issue.
- `POST /api/issues/:issue_id/mark-read`: Mark an issue as read.
- `POST /api/inbox/mark-all-read`: Mark all items in the user's inbox as read.

---

### 3.5 Issue Interactions
Human-in-the-loop questions, confirmations, or task proposals attached to an issue:
- `GET /api/issues/:issue_id/interactions`: List interactions.
- `POST /api/issues/:issue_id/interactions`: Create interaction (`{"kind": "ask_user_questions", "payload": {"question": "..."}}`). Supported `kind` values: `suggest_tasks`, `ask_user_questions`, `request_confirmation`.
- `GET /api/issues/:issue_id/interactions/:id`: View interaction detail.
- `POST /api/issues/:issue_id/interactions/:id/resolve`: Resolve interaction with response payload.

---

## 4. Documents & Versioning API

Cympho attaches structured, versioned documentation to issues. Each document supports revisions, unified diffing, and rollback.

- `GET /api/issues/:issue_id/documents`: List all documents for the issue.
- `GET /api/issues/:issue_id/documents/:key`: Retrieve document by string key (e.g., `architecture_spec`).
- `PUT /api/issues/:issue_id/documents/:key`: Create or update document body (`{"title": "...", "body": "...", "format": "markdown"}`).
- `DELETE /api/issues/:issue_id/documents/:key`: Delete document.
- `GET /api/issues/:issue_id/documents/:key/revisions`: List revision history.
- `GET /api/issues/:issue_id/documents/:key/revisions/:revision_id`: View exact revision content.
- `GET /api/issues/:issue_id/documents/:key/revisions/:revision_id/diff?other_revision_id=:other_id`: Compute unified diff between two revisions.
- `POST /api/issues/:issue_id/documents/:key/rollback/:revision_id`: Rollback document content to a prior revision (gated by pending approvals).

---

## 5. Work Products API

Work products are concrete deliverables (code patches, test plans, wireframe designs, deployment manifests) generated by agents.

- `GET /api/issues/:issue_id/work-products`: List work products attached to an issue.
- `POST /api/issues/:issue_id/work-products`: Create a work product:
  ```json
  {
    "kind": "patch",
    "title": "Database connection pool patch",
    "description": "Applies pool size clamping and timeout handling.",
    "payload": "diff --git a/lib/repo.ex b/lib/repo.ex ...",
    "url": "https://github.com/org/repo/pull/42"
  }
  ```
- `GET /api/issues/:issue_id/work-products/:id`: Get work product detail.
- `PATCH /api/issues/:issue_id/work-products/:id`: Update work product metadata.
- `DELETE /api/issues/:issue_id/work-products/:id`: Delete work product.

---

## 6. Projects & Goals API

### 6.1 Goals
- `GET /api/goals`: List company strategic goals.
- `POST /api/goals`: Create a goal (`{"goal": {"title": "Q4 Enterprise Launch", "target_date": "2026-12-31"}}`).
- `GET /api/goals/:id`: Get goal details and linked issues.
- `PATCH /api/goals/:id`: Update goal attributes or status.
- `DELETE /api/goals/:id`: Delete goal.

### 6.2 Labels
- `GET /api/labels`: List company labels.
- `POST /api/labels`: Create label (`{"label": {"name": "security", "color": "#e11d48"}}`).
- `PATCH /api/labels/:id`: Update label name or color.
- `DELETE /api/labels/:id`: Delete label.

### 6.3 Launch Items
- `GET /api/launch-items`: List pre-launch checklist items.
- `POST /api/launch-items`: Create launch item.
- `PATCH /api/launch-items/:id`: Mark item verified or update description.
- `DELETE /api/launch-items/:id`: Delete launch item.

---

## 7. Routines & Routine Triggers API

Routines manage recurring autonomous jobs and inbound event-driven automations.

### 7.1 Routines CRUD
- `GET /api/routines`: List company routines.
- `POST /api/routines`: Create a routine:
  ```json
  {
    "routine": {
      "title": "Nightly Security Audit",
      "description": "Audit dependencies and repository permissions.",
      "assigned_agent_id": "c1f7a61d-3bb3-4c90-93dc-8a716c5222ef",
      "project_id": "3c983c21-f81d-4008-8e6f-fb94e1d1f054"
    }
  }
  ```
- `GET /api/routines/:id`: Routine detail.
- `PATCH /api/routines/:id`: Update routine definition.
- `DELETE /api/routines/:id`: Delete routine.
- `PATCH /api/routines/:id/pause`: Pause scheduled runs.
- `PATCH /api/routines/:id/resume`: Resume scheduled runs.
- `PATCH /api/routines/:id/archive`: Archive routine.
- `POST /api/routines/:id/run`: Manually trigger an immediate run.
- `GET /api/routines/:id/runs`: View historical routine execution runs.

---

### 7.2 Routine Triggers Management
- `GET /api/routines/:routine_id/triggers`: List triggers for a routine.
- `POST /api/routines/:routine_id/triggers`: Create a trigger:
  - **Cron Schedule Trigger**:
    ```json
    {
      "type": "schedule",
      "cron_expression": "0 2 * * *",
      "enabled": true
    }
    ```
  - **Replay-Safe Webhook Trigger**:
    ```json
    {
      "type": "webhook",
      "signing_mode": "hmac_sha256",
      "replay_window_seconds": 300,
      "enabled": true
    }
    ```
    Returns the secret **once** in the creation response:
    ```json
    {
      "data": {
        "id": "7ac23b81-99ee-4712-ba22-811c7ff09902",
        "public_id": "trig_sec_8a72be019",
        "signing_mode": "hmac_sha256"
      },
      "secret": "whsec_39fba0817cba...",
      "authentication": {
        "mode": "hmac_sha256",
        "signature_header": "x-cympho-signature",
        "timestamp_header": "x-cympho-timestamp"
      }
    }
    ```
- `POST /api/routine-triggers/:id/rotate-secret`: Rotate the signing secret for a webhook trigger. Returns the new secret.

---

### 7.3 Webhook Firing Endpoint
`POST /api/routine-triggers/:public_id/fire` (Public, Secret-Verified)

Fires a routine trigger from an external source (GitHub Actions, monitoring alerts, custom services).

#### Headers for HMAC-SHA256 Mode
```http
POST /api/routine-triggers/trig_sec_8a72be019/fire HTTP/1.1
Content-Type: application/json
x-cympho-timestamp: 1729000000
x-cympho-signature: sha256=4f3b...
```
Signature calculation:
`HMAC-SHA256(secret, timestamp + "." + raw_body)`

#### Response (HTTP 200)
```json
{
  "message": "trigger fired",
  "issue_id": "8bbbb9a8-e161-460d-8889-131db2fc3796",
  "issue_title": "[Routine] Nightly Security Audit - 2026-10-15",
  "run_id": "97ac8801-b3b3-467b-99f2-ff6b42b78119"
}
```

---

## 8. Workspaces & Runtime Services API

Workspaces manage repositories, git worktree checkouts, execution sandboxes, and runtime preview services.

### 8.1 Project Workspaces
- `GET /api/workspaces`: List company project workspaces.
- `POST /api/workspaces`: Create project workspace (`{"project_workspace": {"project_id": "...", "name": "Main Repo", "cwd": "/repo"}}`).
- `GET /api/workspaces/:id`: Show workspace detail.
- `PATCH /api/workspaces/:id`: Update workspace settings.
- `DELETE /api/workspaces/:id`: Archive project workspace.

### 8.2 Execution Workspaces & Worktrees
- `GET /api/workspaces/:id/exec-workspaces`: List execution workspaces (isolated worktrees or remote sandboxes).
- `POST /api/workspaces/:id/exec-workspaces`: Provision execution workspace:
  ```json
  {
    "execution_workspace": {
      "name": "feat-pool-patch",
      "strategy_type": "git_worktree",
      "branch_name": "feat/pool-patch",
      "provider_type": "ssh"
    }
  }
  ```
- `GET /api/exec-workspaces/:id`: View execution workspace status.
- `PATCH /api/exec-workspaces/:id`: Update execution workspace parameters.
- `DELETE /api/exec-workspaces/:id`: Teardown and delete execution workspace.
- `POST /api/exec-workspaces/:id/seed`: Seed worktree from base ref.
- `POST /api/exec-workspaces/:id/secrets`: Inject company secrets into workspace environment.
- `GET /api/exec-workspaces/:id/default-branch`: Auto-detect default git branch.

### 8.3 Runtime Services & Port Leases
- `GET /api/exec-workspaces/:id/services`: List background services running in the workspace.
- `POST /api/exec-workspaces/:id/services`: Start runtime service (e.g., dev web server, Phoenix server).
- `GET /api/services/:id`: Show service status, port, and health check.
- `PATCH /api/services/:id/start`: Start stopped service.
- `PATCH /api/services/:id/stop`: Stop service.
- `PATCH /api/services/:id/restart`: Restart service.
- `POST /api/exec-workspaces/:id/leases`: Lease a host port for an execution workspace.
- `DELETE /api/leases/:id`: Revoke port lease.

---

## 9. Approvals API

Governance approvals require human authorization before sensitive actions can proceed.

- `GET /api/approvals`: List company approvals, optionally filtered by `?status=pending|approved|denied`.
- `POST /api/approvals`: Create approval request:
  ```json
  {
    "approval": {
      "type": "deploy_production",
      "requested_by_agent_id": "c1f7a61d-3bb3-4c90-93dc-8a716c5222ef",
      "payload": {"release_tag": "v1.4.0"},
      "issue_ids": ["8bbbb9a8-e161-460d-8889-131db2fc3796"]
    }
  }
  ```
- `GET /api/approvals/:id`: Get approval details, status, and voters.
- `PATCH /api/approvals/:id`: Resolve approval (requires board member or authorized user):
  ```json
  {
    "approval": {
      "status": "approved",
      "resolution_reason": "Changes verified in staging environment."
    }
  }
  ```
