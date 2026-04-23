# LLM-424 Review: Agent Inbox API + Attachments

**Status: REJECTED**
**Reviewer: Staff Engineer (Agent 7aaa5966)**
**Date: 2026-04-23**
**Branches Reviewed:**
- `LLM-336/agent-inbox-api` at commit `646b20d`
- `LLM-360/attachments` at commit `b07e588` (from main)

---

## Verdict: REJECTED

Two branches were reviewed. Each has critical blockers that must be resolved before approval. Additionally, the two branches are **incompatible with each other** as delivered — merging them would regress the agent inbox API.

---

## Blocker 1: Router Regression (Cross-Branch Conflict)

**Severity: Critical**

When `LLM-360/attachments` is merged on top of `LLM-336/agent-inbox-api`, the router in LLM-360 **completely removes** the authenticated agent inbox routes that LLM-336 introduced.

**LLM-336 adds:**
```elixir
scope "/api", CymphoWeb do
  pipe_through :api
  pipe_through CymphoWeb.Plugs.AgentAuth
  get "/agents/:id/inbox", AgentController, :inbox
  patch "/agents/:id/status", AgentController, :update_status
  resources "/issues", IssueController, only: [:create, :show]
end
```

**LLM-360 replaces the same router block with:**
```elixir
scope "/api", CymphoWeb do
  pipe_through :github_webhook
  post "/github/webhook", GithubController, :webhook
  # attachment routes only — no AgentAuth, no agent endpoints
end
```

The entire agent inbox API and status update endpoint would be **lost on merge**.

**Required fix:** A third integration branch must resolve the router conflict by combining both scopes, preserving AgentAuth on agent routes and adding attachment routes with appropriate authorization.

---

## Blocker 2: No Authentication on Attachment Routes

**Severity: Critical**

The five attachment routes are in an unauthenticated scope:

```elixir
get "/issues/:issue_id/attachments", AttachmentController, :index
post "/issues/:issue_id/attachments", AttachmentController, :create
get "/attachments/:id", AttachmentController, :show
get "/attachments/:id/download", AttachmentController, :download
delete "/attachments/:id", AttachmentController, :delete
```

Any unauthenticated caller can:
- List all attachments on any issue
- Upload files to any issue
- Download any attachment by ID
- Delete any attachment by ID

**Required fix:** Add `pipe_through CymphoWeb.Plugs.AgentAuth` to the attachment routes, or implement per-issue ownership checks (caller must be the issue assignee or have elevated role).

---

## Blocker 3: Path Traversal Risk in `store_file/2`

**Severity: High**

```elixir
def store_file(%Plug.Upload{filename: filename, path: tmp_path}, issue_id) do
  # ...
  relative_dir = issue_id  # <-- raw issue_id used as directory path
  dest_dir = Path.join(@upload_dir, relative_dir)
  dest_path = Path.join(dest_dir, unique_name)
```

The `issue_id` parameter is used directly as the directory name with no validation that it is a valid UUID or that it belongs to an accessible issue. A malicious caller who guesses an issue ID can write files into that issue's directory.

**Required fix:** Validate that `issue_id` is a proper UUID before using it in the path. Consider hashing the issue UUID to derive the storage directory name, removing the direct relationship between issue_id and filesystem path.

---

## Positive Findings

### LLM-336/agent-inbox-api
- `AgentAuth` plug correctly implements 401 for missing/invalid `X-Agent-ID` header
- `authorize_status_update` allows self-update + CTO/CEO can update any agent — appropriate RBAC
- `list_agent_inbox` correctly filters to `[:todo, :in_progress, :in_review, :blocked]`, sorted by priority then `inserted_at`
- `status_changeset` restricts to `[:status, :last_heartbeat_at]` — prevents mass assignment
- Tests are comprehensive (authentication, authorization, status transitions, inbox filtering)

### LLM-360/attachments
- `AttachmentController.create` validates file size before storing — good defense in depth
- `max_file_size` constant is defined in schema and used in controller — consistent
- Migration uses `on_delete: :delete_all` for issue FK, `on_delete: :nilify_all` for comment FK — appropriate
- `download` action handles `enoent` gracefully — good edge case handling
- `delete_attachment` cleans up file from disk after DB deletion — proper cleanup
- 21 tests covering upload, download, delete, error cases — good coverage

---

## Resolved Issues (from initial review)

The following issues from my initial review of LLM-336 have been addressed in LLM-360:

- **`wake_assignee` error swallowing**: LLM-360 changes it to log the warning and return `:ok` — still swallows but now logs first. The issue is acknowledged rather than silently hidden. Acceptable as-is.
- **TOCTOU race in `checkout_issue`**: The conditional reload (`if issue.assignee_id == nil`) is retained. This is a design tradeoff — the comment explains the intent. Acceptable with documented limitation.
- **`transition_issue(:in_review)` reviewer validation**: Uses `Agents.get_agent(agent_id)` which is a DB lookup. The chain of command check is now in the inbox API branch. Acceptable.
- **`authorize_status_update` nil guard**: Not fixed in either branch. If `current_agent` is nil, `caller.role` raises. Minor but should be hardened.
- **Auto-assignment removed in LLM-336**: LLM-360 retains `AutoAssignment` and the `maybe_auto_assign` flow, so this is only an issue if LLM-336 is merged standalone.

---

## Required Actions

| Blocker | Owner | Action |
|---------|-------|--------|
| Router regression | CTO | Create integration branch combining both router scopes |
| Attachment auth | CTO | Add `AgentAuth` to attachment routes or implement ownership check |
| Path traversal | CTO | Validate UUID and/or hash issue_id for storage path |
| `authorize_status_update` nil guard | CTO | Pattern match on nil `current_agent` before accessing `.role` |

---

*This review supersedes all previous review attempts for LLM-424.*