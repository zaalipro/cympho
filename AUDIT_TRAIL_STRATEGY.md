# Audit Trail Retention and Partitioning Strategy

## Table Structure

The `audit_events` table is append-only with the following characteristics:
- **No UPDATE/DELETE**: DB trigger enforces immutability
- **Write-once**: Records inserted only, never modified
- **Time-series**: Queries predominantly filter by `company_id` and `created_at`

## Indexing Strategy

### Primary Index (required at table creation)
```sql
CREATE INDEX audit_events_company_created_type_idx 
ON audit_events (company_id, created_at DESC, event_type);
```

**Rationale**: This composite index supports the most common query pattern:
- Filter by company (multi-tenancy)
- Filter by date range (time-series)
- Filter by event type (optional)

The DESC on `created_at` optimizes for "latest first" display.

### Secondary Indexes (add later if needed)
- `(actor_type, actor_id, created_at)` — for "what did this actor do?" queries
- `(resource_type, resource_id, created_at)` — for "history of this resource" queries

## Partitioning Strategy

### Phase 1: Single table (current)
- Start with unpartitioned table
- Monitor row growth
- Partition when table exceeds 10M rows

### Phase 2: Monthly partitioning (trigger at 10M rows)
Partition by `created_at` month using PostgreSQL declarative partitioning:

```sql
-- Convert to partitioned table (requires table rebuild)
CREATE TABLE audit_events_partitioned (
  -- same schema
) PARTITION BY RANGE (created_at);

-- Create partitions
CREATE TABLE audit_events_2026_04 PARTITION OF audit_events_partitioned
  FOR VALUES FROM ('2026-04-01') TO ('2026-05-01');

CREATE TABLE audit_events_2026_05 PARTITION OF audit_events_partitioned
  FOR VALUES FROM ('2026-05-01') TO ('2026-06-01');
```

**Benefits**:
- Faster queries (scan only relevant month)
- Cheaper deletes (drop entire partitions for archival)
- Better index maintenance (smaller indexes per partition)

### Phase 3: Automated partition management
- Create future partitions 1 month in advance
- Drop partitions older than 90 days after archival

## Retention Policy

### Hot storage: 90 days
- Retain audit events in primary database for 90 days
- Supports compliance investigation window
- Aligns with typical business cycle

### Cold storage: archive after 90 days
- Export partitions to compressed JSON or Parquet
- Upload to S3 (using existing S3 infrastructure)
- Drop partition from database after successful archival
- Archive file naming: `audit_events_YYYY_MM.parquet`

### Retrieval from cold storage
- Manual restore process for compliance requests
- Load archived partition into temporary table for querying
- Document runbook in ops wiki

## Volume Estimates

Assumptions:
- 100 companies, 50 agents each
- 100 audit events per agent per day
- **Daily**: 500,000 events
- **Monthly**: ~15M events
- **Yearly**: ~180M events

At these estimates, we reach the 10M partitioning threshold in ~20 days. Plan to implement partitioning within the first month of production deployment.

## Implementation Notes

1. **Migration**: Start with Phase 1 (single table with composite index)
2. **Monitoring**: Add telemetry for `audit_events` row count and query performance
3. **Partitioning migration**: Create separate issue for Phase 2 when approaching 10M rows
4. **Archival automation**: Create cron job to check for partitions older than 90 days
