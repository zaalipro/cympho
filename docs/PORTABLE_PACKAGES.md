# Portable company packages

A package is a company's blueprint — its projects, agents, goals, labels, and
(for a full export) its users, memberships, and issues — in a form you can move
between installations.

Two things you can do with one:

* **Import** it as a brand-new company (`Cympho.Companies.import_company/2`).
* **Merge** it into a company that already exists
  (`Cympho.Companies.PackageMerge`).

Packages never contain secret values. Export redacts every secret-shaped field,
and `secret_manifest` carries only the restore checklist an operator works
through afterwards.

## Sources

`Cympho.Companies.PortablePackage.load_source/2` accepts:

| Kind | Example |
| --- | --- |
| `:json` | `load_source(:json, "{...}")` or an already-decoded map |
| `:path` | `load_source(:path, "/tmp/acme.json")` |
| `:dir` | `load_source(:dir, "/tmp/acme-package")` |
| `:github` | `load_source(:github, {"owner/repo", ref: "<40-char sha>"})` |

`preview/2`, `import/2`, `merge_preview/3`, and `merge/3` all take the same
source forms directly, so you rarely call `load_source/2` yourself.

## Directory format

```
acme-package/
  cympho-package.json     # manifest
  company.json
  users.json
  memberships.json
  projects.json
  agents.json
  issues.json
  goals.json
  labels.json
  secret_manifest.json
```

The manifest declares the format, version, and which collection files exist:

```json
{
  "format": "cympho.company.package",
  "version": 1,
  "exported_at": "2026-08-14T12:00:00Z",
  "files": {"company": "company.json", "agents": "agents.json"}
}
```

Write one with `PortablePackage.export_dir/3`, which accepts the same
`:includes` option as `export/2`, so a selective export round-trips.

Safety rules the loader enforces:

* A manifest may only name collections from the standard set, and each must use
  its standard filename. A manifest cannot point a collection at another path.
* Every resolved path must stay inside the package root.
* Symlinked collection files are refused outright.
* Files are size-capped (10 MB each) and must be valid JSON. Parse failures
  report the filename, never the file contents.

## Repository sources

```elixir
PortablePackage.merge_preview(
  {:github, {"acme/standards", ref: "9f2b1c...", path: "packages/engineering"}},
  company_id,
  collision: :skip
)
```

* **`:ref` is required and must be a 40-character commit SHA.** Branches and
  tags move, so a package fetched from one is not reproducible. Pass
  `allow_unpinned: true` to accept a branch during development.
* `:path` may name a `.json` file (single-file package) or a directory
  containing `cympho-package.json` (directory package). It defaults to the
  manifest at the repository root.
* `:token` authenticates against a private repository and is never logged.
* Redirects are refused rather than followed — a redirect off the package host
  could point anywhere.

## Merging into an existing company

```elixir
{:ok, plan} = PortablePackage.merge_preview(source, company_id, collision: :skip)
{:ok, result} = PortablePackage.merge(source, company_id, collision: :skip)
```

`merge_preview/3` writes nothing. It returns per-collection counts, the exact
conflicts it found, warnings, and the collections it will not touch.

### Collision modes

Each incoming record is matched against the target company by a natural key —
label name, project prefix, agent name, goal title — compared case-insensitively.
When a match exists:

| Mode | Behaviour |
| --- | --- |
| `:skip` (default) | keep the existing record; package references remap to it |
| `:replace` | update the existing record from the package; references remap to it |
| `:rename` | write a new record under a de-duplicated key (`bug-copy`; project prefixes get a letter suffix, `PLAT` → `PLATA`) |
| `:fail` | abort the whole merge before any write and return the conflicts |

Records with no match are always created.

### What merges

Only blueprint collections: `labels`, `projects`, `goals`, `agents`.

`users`, `memberships`, `issues`, and `secret_manifest` are reported in the
plan's `unsupported` list with a reason rather than merged. Matching identity or
work items by name into a live company would fabricate people or duplicate
history; use whole-company import when you want those.

### Safety

* The whole merge runs in one transaction. An invalid record rolls everything
  back with `{:error, {:invalid_record, collection, errors}}`.
* Packages are structurally validated through `Portability.preview_import/2`
  before any writer runs.
* Redacted secret placeholders are stripped, never persisted as literal values.
* **Created and replaced agents land paused with heartbeat timers disabled.** A
  merge can never start work in a live company on its own; an operator resumes
  the agents deliberately.
* Parent links (goal parents, agent reporting lines) resolve within the merged
  set. Skipped records keep their existing hierarchy untouched.

## Verifying

```bash
mix test test/cympho/companies/package_merge_test.exs \
         test/cympho/companies/package_source_test.exs \
         test/cympho/companies_portability_test.exs
```

The repository-source tests run against a real HTTP server on loopback, so
status handling, redirect refusal, and the HTTP client path are exercised for
real rather than stubbed.
