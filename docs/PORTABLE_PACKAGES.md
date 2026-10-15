# Portable Company Packages

A **Portable Company Package** is a complete, self-contained blueprint of an autonomous company—its projects, agents, role playbooks, goals, labels, and (for full exports) its issues, memberships, and discussion history. Packages allow operators to back up company state, version-control entire company architectures in Git, or migrate organizations across Cympho installations.

---

## 1. Package Architecture & Layout

A package can exist as a single JSON file or as a structured directory. Packages never contain plaintext secrets; all sensitive credentials are automatically redacted during export, producing a restore checklist in `secret_manifest.json`.

### 1.1 Directory Structure
```text
my-company-package/
├── cympho-package.json     # Format manifest and versioning
├── company.json            # Company profile, operating brief, and governance config
├── users.json              # Exported human user accounts (full export only)
├── memberships.json        # User company roles and permissions (full export only)
├── projects.json           # Projects, repository settings, and prefixes
├── agents.json             # Agent definitions, role playbooks, model configs
├── issues.json             # Issue backlog, status, digest, and comments
├── goals.json              # Strategic company goals and milestones
├── labels.json             # Issue categorization labels and colors
└── secret_manifest.json    # Operator checklist of required credentials
```

### 1.2 Manifest Format (`cympho-package.json`)
The manifest declares the schema version and collection file mapping:
```json
{
  "format": "cympho.company.package",
  "version": 1,
  "exported_at": "2026-10-15T12:00:00Z",
  "files": {
    "company": "company.json",
    "projects": "projects.json",
    "agents": "agents.json",
    "goals": "goals.json",
    "labels": "labels.json"
  }
}
```

---

## 2. Exporting Packages

### 2.1 Via Web UI
Board members can export packages from **Company Settings -> Export** (`/companies/:id/export`).
Operators can select:
- **Full Company Export**: Includes issues, users, memberships, and history.
- **Blueprint Only**: Includes only structural definitions (agents, playbooks, projects, goals, labels) suitable for public sharing or reusable company templates.

### 2.2 Programmatic Export
Export directly to a directory using Elixir Mix or IEx:
```elixir
# Export full company
Cympho.Companies.PortablePackage.export_dir(company_id, "/var/backups/company_export")

# Export selective blueprint
Cympho.Companies.PortablePackage.export_dir(
  company_id,
  "/var/backups/blueprint_export",
  includes: [:projects, :agents, :goals, :labels]
)
```

---

## 3. Resumable Chunked Import Transfer

Importing large packages (which may contain megabytes of issue history or attachments) uses Cympho's resumable chunked transfer protocol.

### 3.1 Browser Import UI (`/companies/import`)
- Access requires board governance authority.
- The browser hashes and streams the package file in 4 MiB slices.
- If network connectivity drops or the page reloads, re-selecting the file resumes from the last confirmed part without re-uploading completed chunks.
- Validates cryptographic SHA-256 integrity before commit.

### 3.2 REST API Transfer Flow
JWT clients consume the equivalent transfer endpoints under `/api/companies/import/transfers`:

1. **Declare Manifest**:
   `POST /api/companies/import/transfers`
   ```json
   {
     "idempotency_key": "import-acme-20261015",
     "total_bytes": 16777216,
     "part_size_bytes": 4194304,
     "file_sha256": "4b82ca...",
     "import_options": {
       "slug_strategy": "preserve"
     },
     "parts": [
       {"position": 1, "byte_size": 4194304, "sha256": "e3b0c4..."},
       {"position": 2, "byte_size": 4194304, "sha256": "8a91cf..."}
     ]
   }
   ```
2. **Upload Parts**:
   `PUT /api/companies/import/transfers/:id/parts/:position`
   - Content-Type: `application/octet-stream`
   - Raw binary part payload matching the declared SHA-256.
3. **Inspect Progress**:
   `GET /api/companies/import/transfers/:id`
   - Returns upload percentage and received part positions.
4. **Validation Preview**:
   `POST /api/companies/import/transfers/:id/preview`
   - Validates entity relationships, schemas, and references without writing to production tables.
5. **Atomic Commit**:
   `POST /api/companies/import/transfers/:id/apply`
   - Commits the full company graph inside a single database transaction.

### 3.3 Storage & Persistence (`CYMPHO_IMPORT_SPOOL_DIR`)
Production environments must configure a dedicated persistent directory for upload parts:
```bash
CYMPHO_IMPORT_SPOOL_DIR=/opt/cympho/data/import-transfers
```
Parts are verified with SHA-256 and installed atomically via `fsync` and atomic file rename.

---

## 4. Merging into an Existing Company

Packages can be merged into an existing company rather than creating a new one:
```elixir
alias Cympho.Companies.PortablePackage

# Preview plan
{:ok, plan} = PortablePackage.merge_preview(source, target_company_id, collision: :skip)

# Apply merge
{:ok, result} = PortablePackage.merge(source, target_company_id, collision: :skip)
```

### 4.1 Collision Modes
When an incoming record matches an existing record in the target company (e.g., matching agent name, project prefix, or label name):

| Mode | Behavior |
|---|---|
| `:skip` (default) | Preserves existing target record. Incoming references remap to the existing record. |
| `:replace` | Updates existing record with attributes from the incoming package. |
| `:rename` | Creates a new record with a deduplicated name (e.g., `engineer-2`, project prefix `WEB` → `WEBA`). |
| `:fail` | Aborts the entire merge before writing and returns the list of conflicting keys. |

### 4.2 Merge Scope & Safety Boundaries
- **Blueprint Only**: Merges only `labels`, `projects`, `goals`, and `agents`.
- **Identity & Work Isolation**: `users`, `memberships`, and `issues` are excluded from merges to prevent identity spoofing or ticket duplication. Use whole-company import when migrating complete histories.
- **Safe Agent Landing**: All newly created or updated agents land in **`paused` status with heartbeat timers disabled**. Agents will never begin autonomous execution without deliberate operator resumption.
- **Atomic Rollback**: Merges run within a single Ecto transaction. Any schema error rolls back all modifications.

---

## 5. Verification & Testing

Verify package export, import, and merge pipelines:
```bash
mix test test/cympho/companies/package_merge_test.exs \
         test/cympho/companies/package_source_test.exs \
         test/cympho/companies_portability_test.exs
```
These tests run against real database transactions and verify SHA-256 part reassembly, collision handling, and tenant isolation.
