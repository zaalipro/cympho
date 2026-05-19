defmodule Cympho.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Cympho.Repo,
      {Phoenix.PubSub, name: Cympho.PubSub},
      {Task.Supervisor, name: Cympho.TaskSupervisor},
      {Registry, keys: :unique, name: Cympho.OrchestratorRegistry},
      {Registry, keys: :unique, name: Cympho.AgentHeartbeat.Registry},
      Cympho.AgentHeartbeat.Supervisor,
      Cympho.Issues.AutoAssignmentReassigner,
      # Layer 2: NotificationSupervisor
      {Cympho.Notifications.NotificationSupervisor, []},
      heartbeat_watchdog_child(),
      board_approval_executor_child(),
      scheduler_child(),
      # HTTP client for adapters and notifications
      {Finch, name: Cympho.Finch},
      # Adapter system
      Cympho.Adapters.Registry,
      health_checker_child(),
      # Plugin system
      {Registry, keys: :unique, name: Cympho.PluginRegistry},
      Cympho.Plugins.Registry,
      {Cympho.Plugins.Supervisor, []},
      # Skill hot-reload for development
      {Cympho.Skills.HotReloader, []},
      # Rate limiting (must precede Dispatcher: orphan recovery broadcasts
      # via BroadcastDedup, which owns an ETS table created in init/1).
      Cympho.RateLimiting.BroadcastDedup,
      Cympho.RateLimiting.IpRateLimiter,
      Cympho.RateLimiting.AgentActionLimiter,
      Cympho.WebhookDedup,
      Cympho.EventStore,
      Cympho.Orchestrator.Dispatcher,
      backlog_planner_child(),
      oversight_patrol_child(),
      CymphoWeb.Endpoint
    ]

    children = Enum.reject(children, &is_nil/1)
    opts = [strategy: :one_for_one, name: Cympho.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Adapters.Registry now registers builtins from its own init/1, so the
        # late-binding call here was a redundant double-registration.
        # Routine triggers are scheduled in a task so a transient failure
        # doesn't take down boot.
        schedule_routine_triggers()

        {:ok, pid}

      error ->
        error
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CymphoWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # The executor subscribes to PubSub and queries the DB on every approval
  # event. In tests it has no sandbox connection, so any approval created by
  # an async test (most of them) would crash it; the supervisor would restart
  # it; eventually max-restarts would take down the whole tree (including
  # the Repo). Tests that exercise the executor opt in via `start_supervised`.
  defp board_approval_executor_child do
    if Application.get_env(:cympho, :start_board_approval_executor?, true) do
      Cympho.BoardApprovals.BoardApprovalActionExecutor
    end
  end

  # The watchdog runs DB queries on a timer and on `check_now/0`. Same problem
  # as the executor: no sandbox in test env. Watchdog tests opt in.
  defp heartbeat_watchdog_child do
    if Application.get_env(:cympho, :start_heartbeat_watchdog?, true) do
      Cympho.HeartbeatEngine.Watchdog
    end
  end

  # The health checker runs DB queries on a timer (`:check_all`). Same problem
  # as the executor and watchdog: in test env it has no sandbox connection, and
  # repeated crashes blow up the supervisor restart budget and take down Repo.
  defp health_checker_child do
    if Application.get_env(:cympho, :start_health_checker?, true) do
      {Cympho.AgentAdapters.HealthChecker, []}
    end
  end

  defp scheduler_child do
    if Application.get_env(:cympho, :start_scheduler?, true) do
      Cympho.Scheduler
    end
  end

  # The backlog planner runs periodic DB queries (Companies.list_companies,
  # active issue counts, mission goal counts) and writes wakes. Same test
  # constraint as the watchdog/executor: no Ecto sandbox connection in test
  # env. Tests opt in via Application.put_env or start_supervised.
  defp backlog_planner_child do
    if Application.get_env(:cympho, :start_backlog_planner?, true) do
      Cympho.Orchestrator.BacklogPlanner
    end
  end

  # The oversight patrol watches for stalled issues and wakes their
  # supervisor. Same DB-query / sandbox constraint as the others.
  defp oversight_patrol_child do
    if Application.get_env(:cympho, :start_oversight_patrol?, true) do
      Cympho.Oversight.Patrol
    end
  end

  defp schedule_routine_triggers do
    if Application.get_env(:cympho, :schedule_routine_triggers?, true) do
      Task.Supervisor.start_child(
        Cympho.TaskSupervisor,
        fn -> Cympho.RoutineTriggers.schedule_all_triggers() end,
        restart: :temporary
      )
    end
  end
end
