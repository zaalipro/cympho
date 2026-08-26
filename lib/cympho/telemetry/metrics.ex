defmodule Cympho.Telemetry.Metrics do
  @moduledoc """
  Metric definitions and periodic VM/runtime measurements.

  `Cympho.Telemetry` already emits domain events (`[:cympho, :issue, :created]`,
  `[:cympho, :run, :lifecycle]`, `[:cympho, :dispatcher, :dispatch]`, …) from
  real call sites, but nothing was ever attached to them, so none of it reached
  an operator. This module supplies the reporter-agnostic definitions those
  events need — LiveDashboard consumes them directly, and any
  `Telemetry.Metrics` reporter (StatsD, Prometheus, OTLP) can consume the same
  list without changing a single emit site.

  It also runs a `:telemetry_poller` for measurements the BEAM can answer but a
  request-scoped event cannot: run-queue depth, per-scheduler load, and the
  mailbox depth of the singleton processes every dispatch and broadcast flows
  through. Those queues are the system's real chokepoints, and until now their
  depth was invisible.

  `Cympho.Telemetry.setup/0` is a separate, unused legacy path that re-emits
  every event as `[:cympho, :event, :logged]`. It is intentionally still not
  called; attaching it would double every event for no consumer.
  """

  use Supervisor

  import Telemetry.Metrics

  @poll_period :timer.seconds(10)

  # DynamicSupervisors with a hard ceiling. Hitting one turns
  # `start_for_agent/1` or a plugin start into a silent `:max_children` error,
  # and nothing surfaced how close an install was to that wall.
  @bounded_supervisors [
    {Cympho.AgentHeartbeat.Supervisor, :agent_heartbeats, 500},
    {Cympho.Plugins.Supervisor, :plugins, 100}
  ]

  # Processes every dispatch or realtime broadcast has to pass through. A
  # growing mailbox here means the whole install is falling behind.
  @singletons [
    {Cympho.Orchestrator.Dispatcher, :dispatcher},
    {Cympho.RuntimeAdmission, :runtime_admission},
    {Cympho.EventStore, :event_store},
    {Cympho.RateLimiting.BroadcastDedup, :broadcast_dedup},
    {Cympho.RateLimiting.IpRateLimiter, :ip_rate_limiter},
    {Cympho.RateLimiting.AgentActionLimiter, :agent_action_limiter}
  ]

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller,
       measurements: periodic_measurements(), period: @poll_period, name: Cympho.TelemetryPoller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Metric definitions for LiveDashboard and any `Telemetry.Metrics` reporter.

  Tags are deliberately low cardinality — no `company_id`, `issue_id`, or
  `agent_id` — so a large install cannot create an unbounded number of series.
  """
  def metrics do
    vm_metrics() ++
      runtime_metrics() ++ phoenix_metrics() ++ database_metrics() ++ domain_metrics()
  end

  defp vm_metrics do
    [
      last_value("vm.memory.total", unit: {:byte, :megabyte}),
      last_value("vm.memory.processes", unit: {:byte, :megabyte}),
      last_value("vm.memory.ets", unit: {:byte, :megabyte}),
      last_value("vm.memory.binary", unit: {:byte, :megabyte}),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),
      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.port_count"),
      last_value("vm.system_counts.atom_count")
    ]
  end

  defp runtime_metrics do
    [
      last_value("cympho.runtime.orchestrators.count",
        description: "Live per-issue orchestrator processes"
      ),
      last_value("cympho.runtime.heartbeats.count",
        description: "Live per-agent heartbeat processes"
      ),
      last_value("cympho.runtime.tasks.count",
        description: "Children of the shared Task.Supervisor"
      ),
      last_value("cympho.runtime.singleton.message_queue_len",
        tags: [:process],
        description: "Mailbox depth of a process every dispatch or broadcast passes through"
      ),
      last_value("cympho.runtime.singleton.memory",
        tags: [:process],
        unit: {:byte, :kilobyte}
      ),
      last_value("cympho.runtime.singleton.alive",
        tags: [:process],
        description: "1 when the singleton is running, 0 when it is down"
      ),
      last_value("cympho.runtime.supervisor.children",
        tags: [:supervisor],
        description: "Live children under a DynamicSupervisor with a hard ceiling"
      ),
      last_value("cympho.runtime.supervisor.max_children",
        tags: [:supervisor],
        description: "The ceiling that turns further starts into :max_children errors"
      ),
      last_value("cympho.runtime.supervisor.saturation_pct",
        tags: [:supervisor],
        description: "How close this supervisor is to refusing new children"
      ),
      counter("cympho.runtime_admission.checkout.count",
        tags: [:execution_class, :outcome, :reason]
      ),
      counter("cympho.runtime_admission.available.count",
        tags: [:execution_class, :outcome, :reason]
      ),
      counter("cympho.runtime_admission.release.count",
        tags: [:execution_class, :outcome, :reason]
      ),
      last_value("cympho.runtime_admission.checkout.local_running"),
      last_value("cympho.runtime_admission.checkout.total_running"),
      last_value("cympho.runtime_admission.checkout.gateway_running"),
      last_value("cympho.runtime_admission.available.local_running"),
      last_value("cympho.runtime_admission.available.total_running"),
      last_value("cympho.runtime_admission.available.gateway_running"),
      last_value("cympho.runtime_admission.release.local_running"),
      last_value("cympho.runtime_admission.release.total_running"),
      last_value("cympho.runtime_admission.release.gateway_running")
    ]
  end

  defp phoenix_metrics do
    [
      summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration", unit: {:native, :millisecond}),
      counter("phoenix.channel_joined.count"),
      counter("phoenix.socket_connected.count")
    ]
  end

  defp database_metrics do
    [
      summary("cympho.repo.query.total_time", unit: {:native, :millisecond}),
      summary("cympho.repo.query.query_time", unit: {:native, :millisecond}),
      summary("cympho.repo.query.queue_time", unit: {:native, :millisecond}),
      summary("cympho.repo.query.idle_time", unit: {:native, :millisecond})
    ]
  end

  # Only events with a real emitter in `Cympho.Telemetry` are defined here. A
  # metric for an event nobody dispatches reads as coverage the install does not
  # have.
  defp domain_metrics do
    [
      counter("cympho.issue.created.count", tags: [:priority]),
      counter("cympho.issue.transitioned.count", tags: [:from, :to]),
      counter("cympho.agent.assigned.count"),
      counter("cympho.agent.status_changed.count", tags: [:to]),
      counter("cympho.kanban.card_moved.count"),
      counter("cympho.onboarding.completed.count"),
      counter("cympho.run.lifecycle.count", tags: [:action, :status]),
      summary("cympho.run.lifecycle.duration_ms", tags: [:action]),
      counter("cympho.dispatcher.dispatch.count", tags: [:status, :role])
    ]
  end

  @doc """
  Functions the poller calls on each tick.
  """
  def periodic_measurements do
    [
      {__MODULE__, :dispatch_runtime_measurements, []},
      {__MODULE__, :dispatch_singleton_measurements, []},
      {__MODULE__, :dispatch_supervisor_measurements, []}
    ]
  end

  @doc """
  Emits how close each bounded DynamicSupervisor is to its ceiling.
  """
  def dispatch_supervisor_measurements do
    Enum.each(@bounded_supervisors, fn {module, tag, ceiling} ->
      children = dynamic_supervisor_children(module)

      :telemetry.execute(
        [:cympho, :runtime, :supervisor],
        %{
          children: children,
          max_children: ceiling,
          saturation_pct: round(children * 100 / ceiling)
        },
        %{supervisor: tag}
      )
    end)
  end

  defp dynamic_supervisor_children(module) do
    case Process.whereis(module) do
      nil -> 0
      pid -> pid |> DynamicSupervisor.count_children() |> Map.get(:active, 0)
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end

  @doc """
  Emits counts of the supervised process populations.

  Every lookup is defensive: a registry or supervisor that is not running yet
  simply reports zero rather than crashing the poller.
  """
  def dispatch_singleton_measurements do
    Enum.each(@singletons, fn {module, tag} ->
      case Process.whereis(module) do
        nil ->
          :telemetry.execute([:cympho, :runtime, :singleton], %{alive: 0}, %{process: tag})

        pid ->
          info = Process.info(pid, [:message_queue_len, :memory])

          measurements =
            case info do
              [{:message_queue_len, queue}, {:memory, memory}] ->
                %{alive: 1, message_queue_len: queue, memory: memory}

              _ ->
                %{alive: 0}
            end

          :telemetry.execute([:cympho, :runtime, :singleton], measurements, %{process: tag})
      end
    end)
  end

  @doc """
  Emits live process-population counts for the orchestration layer.
  """
  def dispatch_runtime_measurements do
    :telemetry.execute(
      [:cympho, :runtime, :orchestrators],
      %{count: registry_count(Cympho.OrchestratorRegistry)},
      %{}
    )

    :telemetry.execute(
      [:cympho, :runtime, :heartbeats],
      %{count: registry_count(Cympho.AgentHeartbeat.Registry)},
      %{}
    )

    :telemetry.execute(
      [:cympho, :runtime, :tasks],
      %{count: supervisor_child_count(Cympho.TaskSupervisor)},
      %{}
    )
  end

  defp registry_count(name) do
    case Process.whereis(name) do
      nil -> 0
      _pid -> Registry.count(name)
    end
  rescue
    _ -> 0
  end

  defp supervisor_child_count(name) do
    case Process.whereis(name) do
      nil -> 0
      pid -> pid |> Task.Supervisor.children() |> length()
    end
  rescue
    _ -> 0
  catch
    :exit, _ -> 0
  end
end
