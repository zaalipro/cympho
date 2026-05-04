# Audit Trail Strategy

## Overview

The Cympho audit trail system provides comprehensive tracking of all governance decisions, budget changes, and board votes across the platform. This document describes the architecture and implementation strategy for audit trail instrumentation.

## Core Components

### 1. GovernanceAuditLogs Module

The `Cympho.GovernanceAuditLogs` module provides the base infrastructure for recording audit events:

- **Schema**: `Cympho.GovernanceAuditLogs.GovernanceAuditLog`
- **Primary Fields**:
  - `action_type`: The type of action performed (e.g., "decision_created", "budget_threshold_change")
  - `actor_type` / `actor_id`: Who performed the action
  - `resource_type` / `resource_id`: What resource was affected
  - `decision`: Human-readable description of the action
  - `reasoning`: Detailed reasoning for the decision
  - `metadata`: Additional context (JSON map)
  - **`inserted_at`**: Timestamp when the log entry was created (Ecto default)

### 2. AuditTrail.Instrumenter Module

The `Cympho.AuditTrail.Instrumenter` module provides a high-level API for recording specific types of audit events:

#### `record_decision/4`

Records decision lifecycle events (created, updated, reversed, superseded).

**Parameters:**
- `decision_id`: The UUID of the decision
- `event`: The event type atom (`:created`, `:updated`, `:reversed`, `:superseded`)
- `issue`: The issue struct/map associated with the decision
- `actor_id`: The UUID of the actor who performed the action

**Example:**
```elixir
Instrumenter.record_decision(decision.id, :created, issue, actor_id)
```

#### `record_budget_change/5`

Records budget configuration changes (threshold changes, limit changes, creation).

**Parameters:**
- `budget_id`: The UUID of the budget
- `event`: The event type string (`"threshold_change"`, `"limit_change"`, `"created"`)
- `old_value`: The previous value
- `new_value`: The new value
- `company_id`: The UUID of the company

**Example:**
```elixir
Instrumenter.record_budget_change(updated.id, "threshold_change", old_threshold, new_threshold, company.id)
```

#### `record_board_vote/4`

Records board member votes on proposals.

**Parameters:**
- `user_id`: The UUID of the user casting the vote
- `vote`: The vote value (`"approve"`, `"deny"`, `"abstain"`)
- `issue`: The board approval issue/struct
- `board_approval_id`: The UUID of the board approval

**Example:**
```elixir
Instrumenter.record_board_vote(user_id, vote, issue, board_approval.id)
```

#### `list_resource_history/3`

Retrieves audit history for a specific resource.

**Parameters:**
- `resource_type`: The type of resource (`"decision"`, `"budget"`, `"board_approval"`)
- `resource_id`: The UUID of the resource
- `company_id`: The UUID of the company (for scoping)

**Returns:**
- List of `GovernanceAuditLog` entries ordered by `inserted_at` descending (newest first)

**Example:**
```elixir
history = Instrumenter.list_resource_history("decision", decision_id, company_id)
```

## Integration Points

### Decisions Module

The `Cympho.Decisions` module calls `Instrumenter.record_decision/4` when:

- A new decision is created via `create_decision/2`
- Decision lifecycle events occur (reversal, supersession)

### Budgets Module

The `Cympho.Budgets` module calls `Instrumenter.record_budget_change/5` when:

- Budget threshold values change
- Budget limit values change
- Budgets are created

### BoardApprovals Module

The `Cympho.BoardApprovals` module calls `Instrumenter.record_board_vote/4` when:

- Board members cast votes on proposals via `cast_vote/4`

## Timestamps

All audit log entries use Ecto's standard timestamp field `inserted_at` to track when events occurred. This field is automatically set by Ecto and represents the time the log entry was created in the database.

**Note:** The field is `inserted_at`, not `created_at`. This follows Ecto's convention for timestamps.

## PubSub Broadcasting

Audit events are broadcast via Phoenix.PubSub on the `"governance_audit"` topic for real-time monitoring:

```elixir
{:audit_log_created, %GovernanceAuditLog{}}
```

## Metadata Structure

Audit log metadata is stored as a JSON map and includes:

- **Decision events**: `decision_id`, `event`, `issue_id`, `issue_title`
- **Budget events**: `budget_id`, `event`, `old_value`, `new_value`, `company_id`
- **Board vote events**: `user_id`, `vote`, `board_approval_id`, `issue_id`, `category`

## Testing

The audit trail system is tested in `test/cympho/audit_trail/instrumenter_test.exs` with comprehensive coverage of:

- Event recording for all instrumenter functions
- Metadata validation
- Resource history retrieval
- Company scoping
- Timestamp ordering

## Future Enhancements

Potential improvements to consider:

1. **Retention policies**: Automatic cleanup of old audit logs
2. **Archival**: Moving old logs to cold storage
3. **Export**: CSV/JSON export functionality for compliance
4. **Search**: Full-text search across audit trail entries
5. **Aggregation**: Summary statistics and trend analysis
