# Resource benchmarks

## Idle-agent heartbeat harness

The idle-agent harness measures the cost of keeping a fleet online when there
are no issues to run. It is **observational**: results are JSON data, not a
machine-specific pass/fail gate.

It is deliberately non-destructive and refuses to run outside `MIX_ENV=test`.
The task checks out an Ecto SQL Sandbox owner in shared mode, creates one
temporary active company and the requested idle agents inside that sandbox
transaction, starts their real heartbeat workers, and rolls the transaction
back after stopping every worker. Exceptions and ordinary completion use an
explicit cleanup path; terminating the VM also closes the sandbox connection,
which PostgreSQL rolls back. It never resets or truncates the test database.

Each fixture stores the minimum accepted heartbeat interval, 5 seconds. The
task warms the workers once so legacy direct mode starts the observation window
with its 5-second timers armed. Delegated mode is event-driven and therefore
keeps no idle timers; its warmup is a DB-free no-op. Fixture inserts and warmup
are excluded from query counts. Repo query telemetry and periodic BEAM samples
then record:

- query count, query time, and queries/second;
- BEAM total, process, and used-process memory;
- total BEAM process count and reductions;
- live heartbeat workers, their aggregate process memory, and active timers;
- final live/idle worker counts as correctness evidence.

Run the default delegated/event-driven path:

```bash
MIX_ENV=test mix cympho.benchmark_idle_agents \
  --agents 100 --duration-ms 30000 --sample-ms 1000 \
  --mode delegated --json tmp/benchmarks/idle-100-delegated.json
```

Measure the legacy direct path with the identical workload:

```bash
MIX_ENV=test mix cympho.benchmark_idle_agents \
  --agents 100 --duration-ms 30000 --sample-ms 1000 \
  --mode direct --json tmp/benchmarks/idle-100-direct.json
```

The task prints a human summary followed by compact JSON on the last stdout
line. `--json` additionally writes stable pretty JSON suitable for retaining as
an artifact. Compare matched runs on the same otherwise-idle host; do not treat
results from different hardware, scheduler counts, database configuration, or
observation durations as equivalent. The harness starts workers directly (but
still through the real `AgentHeartbeat` implementation and Registry) so the
production supervisor's current 500-child safety bound does not invalidate a
1,000-agent measurement.

## Future Cympho/Paperclip cross-app matrix

Do not claim a multiplier from this harness alone. A fair cross-app comparison
needs equivalent released revisions, database state, model/gateway stubs,
hardware limits, warmup, observation windows, and correctness checks. Run at
least this matrix for **both** applications:

| Workload | Required scales / shape |
| --- | --- |
| Idle fleet | 100, 500, and 1,000 online agents; no runnable work |
| Gateway-active | 10, 25, and 50 concurrent agents using a deterministic gateway stub |
| Wake storm | burst and sustained wakes, including repeated wakes for the same agent, with fixed fleet and issue counts |
| Restart recovery | terminate the app during checked-out work, restart it, and measure recovery without duplicate or stranded work |

Every cell must retain raw time-series data and report:

- host/container RSS baseline, peak, steady-state, and per-agent slope;
- CPU user/system time and normalized core utilization;
- database queries/second, total queries, connection-pool pressure, and slow
  query attribution;
- p50/p95/p99 wake-to-start and run/recovery latency as applicable;
- throughput for active workloads;
- correctness: exactly-once checkout/run accounting, no lost or duplicate
  wakes, no stranded locks/runs, expected final issue and agent states, and
  successful worker/runtime recovery;
- failures, restarts, queue depth, and resource-limit/OOM events.

Only matched repetitions with correctness intact should feed later comparative
claims. Publish medians and dispersion across multiple runs rather than a
single best result.

`mix cympho.compare` does not accept a comparative filename as evidence by
itself. The reserved artifact
`benchmarks/results/paperclip-cympho-low-vps.json` must use schema
`cympho.paperclip.low-vps-comparison` version 1 and validate all of the
following before it can even become a candidate for matched evidence:

- exact Cympho and audited Paperclip Git revisions, both marked `dirty: false`,
  plus product runtime-config hashes;
- a Linux cgroup-v2 host with explicit CPU, memory, swap, and PID limits,
  distinct measured cgroup IDs, and identical limits recorded for each product;
- a low-VPS ceiling of at most 2 CPU cores, 2 GiB memory, 2 GiB swap, and 4,096
  PIDs for the total measured host slice, with app and database child limits
  fitting inside that total;
- one shared PostgreSQL engine/version, pool size, and configuration hash, plus
  one shared benchmark-runner hash, helper hash, duration, warmup, and randomized
  ABBA repetition-order policy;
- matched `idle-100`, `idle-500`, `idle-1000`, `active-10`, `active-25`,
  `active-50`, burst/sustained 100-agent wake-storm, and 25-agent restart
  recovery cells, each with an exact hashed scenario whose operation, wake,
  restart, recovery, and completion counts agree with every retained trial.
  Scenario hashes use compact UTF-8 JSON with object keys sorted
  lexicographically;
- at least five repetitions per product and cell, matched by trial ID;
- app, database, and child-process memory/CPU metrics, database query count and
  rate, throughput, and p95 latency;
- zero lost, duplicate, stranded, OOM, and recovery-failure events with
  `correctness.pass: true`;
- three distinct, confined raw references per repetition (`samples`, `events`,
  and `database`) whose SHA-256 checksums match files beside the manifest; and
- top-level `claim_eligible: true`.

Missing, empty, malformed, stale, incomplete, checksum-invalid, or
correctness-failing artifacts remain an open gap. Passing this structural gate
also remains a gap today: raw samples, events, and database files are
checksum-bound but their contents are not yet schema-validated and recomputed
against every declared metric and correctness result. That reconciliation is
required before the comparator may report evidence-contract parity. Neither
state asserts that Cympho won a metric or achieved any multiplier.

## 2026-08-26 development measurement: delegated vs direct

A matched local run on the project toolchain (Elixir 1.19.5, OTP 28, eight
online schedulers) observed 100 idle workers for 5.1 seconds with 5-second
heartbeat intervals. This is a Cympho before/after workload comparison on a
macOS development machine, **not** a Paperclip comparison or low-VPS claim.

| Mode | Idle DB queries | Query rate | Active heartbeat timers | Peak aggregate heartbeat-worker memory |
| --- | ---: | ---: | ---: | ---: |
| Delegated/event-driven | 0 | 0.00 qps | 0 | 584,232 bytes |
| Legacy direct | 800 | 154.41 qps | 100 | 13,742,536 bytes |

Both runs finished with all 100 workers alive and idle. Fixture setup and the
one warmup event were excluded from the query window. The result demonstrates
that the event-driven path removes this specific linear idle timer/database
cost; it does not establish whole-application RSS, active-run throughput,
production reliability, or a cross-product multiplier.

Raw artifacts:

- [`benchmarks/results/2026-08-26-idle-100-delegated.json`](../benchmarks/results/2026-08-26-idle-100-delegated.json)
- [`benchmarks/results/2026-08-26-idle-100-direct.json`](../benchmarks/results/2026-08-26-idle-100-direct.json)
