# Performance & Resource Benchmarks

Cympho includes dedicated benchmarking harnesses to measure runtime concurrency, fleet idle costs, database query overhead, and BEAM process efficiency.

---

## 1. Idle-Agent Heartbeat Harness

The idle-agent harness measures the overhead of keeping an autonomous agent fleet online when there is no active work to execute.

### 1.1 Non-Destructive Sandbox Methodology
The harness (`mix cympho.benchmark_idle_agents`) is non-destructive and strictly gated to `MIX_ENV=test`:
- Checks out an Ecto SQL Sandbox connection in shared mode.
- Creates an ephemeral company and the requested number of idle agents inside that single sandbox transaction.
- Starts real `AgentHeartbeat` workers registered in `AgentHeartbeat.Registry`.
- Collects periodic BEAM system metrics and query telemetry for the specified duration.
- Stops all workers and rolls back the sandbox transaction upon completion or exit. It **never resets or truncates** the development or test databases.

### 1.2 Execution Modes
The harness compares two operational architectures:
1. **Delegated (Event-Driven)**: Agents remain completely dormant while idle, waking only when the Dispatcher or PubSub assigns work. No polling timers are created.
2. **Direct (Legacy Timer-Based)**: Each agent maintains an independent 5-second polling timer that queries the database for runnable work.

### 1.3 Running the Benchmark

Run the default delegated event-driven benchmark with 100 agents:
```bash
MIX_ENV=test mix cympho.benchmark_idle_agents \
  --agents 100 --duration-ms 30000 --sample-ms 1000 \
  --mode delegated --json tmp/benchmarks/idle-100-delegated.json
```

Run the legacy direct timer-based benchmark for comparison:
```bash
MIX_ENV=test mix cympho.benchmark_idle_agents \
  --agents 100 --duration-ms 30000 --sample-ms 1000 \
  --mode direct --json tmp/benchmarks/idle-100-direct.json
```

---

## 2. Benchmark Results: Delegated vs. Direct Mode

The table below reflects measurements taken on a standard 8-core development machine (Elixir 1.19.5, Erlang/OTP 28) observing 100 idle workers over an observation window with 5-second heartbeat intervals:

| Metric | Delegated (Event-Driven) | Direct (Timer Polling) | Impact |
|---|---:|---:|---|
| **Idle Database Queries** | **0** | 800 | 100% reduction in idle database load |
| **Idle Query Rate** | **0.00 qps** | 154.41 qps | Eliminates constant DB connection burn |
| **Active Heartbeat Timers** | **0** | 100 | Eliminates timer drift and wake storms |
| **Peak Worker Memory** | **584 KB** | 13.7 MB | ~23x lower memory footprint for idle workers |
| **Worker Survival** | 100% (100/100 alive) | 100% (100/100 alive) | Full process health maintained |

### Artifact References
Raw benchmark JSON outputs are stored in:
- `benchmarks/results/2026-08-26-idle-100-delegated.json`
- `benchmarks/results/2026-08-26-idle-100-direct.json`

---

## 3. Concurrency & Runtime Capacity Controls

Cympho protects system resources under heavy workloads using tiered capacity limits defined in `Cympho.RuntimeCapacity`:

### 3.1 Node-Wide Total Run Gates
- Limits the maximum number of concurrent agent sessions across the entire BEAM node.
- Incoming dispatches beyond this limit remain safely queued in PostgreSQL rather than spawning unbounded OS processes.

### 3.2 Local Process Sub-Limits
- Local CLI-based adapters (Claude Code, Cursor, Codex, Process) execute resource-heavy subprocesses that consume hundreds of megabytes of RAM.
- Cympho maintains an explicit local-process sub-limit (e.g., maximum 4 concurrent local CLI runs), while allowing lightweight gateway work (Agrenting, HTTP, OpenAI chat completions) to utilize remaining node slots.

### 3.3 Dynamic Host Headroom Checks
In production environments, Cympho probes cgroup-v2 or host OS memory pressure before spawning a new local CLI worker. If available system RAM falls below the configured safety threshold, new local runs are paused until earlier runs finish.

---

## 4. Cross-Platform Comparison Methodology

When comparing Cympho against alternative agent orchestration platforms (e.g., Paperclip), fair evaluation requires testing both systems under identical workloads on low-resource environments:

### 4.1 Required Test Matrix
| Workload | Scale & Parameters | Evaluation Criteria |
|---|---|---|
| **Idle Fleet** | 100, 500, and 1,000 online agents with zero runnable work | RSS memory, idle database queries, CPU utilization |
| **Gateway Active** | 10, 25, and 50 concurrent agents calling mock LLM endpoints | Run latency, throughput, connection pool pressure |
| **Wake Storm** | Burst of 100 wakes fired simultaneously for 20 agents | Coalescing efficiency, queue depth, zero lost wakes |
| **Restart Recovery** | Abrupt VM termination during active runs, followed by restart | Zero duplicate runs, clean lock release, no stranded tasks |

### 4.2 Automated Comparison Verification
To run local regression checks against known architectural milestones:
```bash
mix cympho.compare           # Human-readable comparison table
mix cympho.compare --json    # Machine-readable evaluation report
mix cympho.compare --strict  # Exits non-zero if any regression check fails
```
For the comprehensive upstream gap analysis, refer to [`paperclip_gap.md`](../paperclip_gap.md).
