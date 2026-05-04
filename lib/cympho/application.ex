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
      Cympho.Orchestrator.Dispatcher,
      Cympho.HeartbeatEngine.Watchdog,
      Cympho.BoardApprovals.BoardApprovalActionExecutor,
      Cympho.Scheduler,
      # HTTP client for adapters and notifications
      {Finch, name: Cympho.Finch},
      # Adapter system
      Cympho.Adapters.Registry,
      {Cympho.AgentAdapters.HealthChecker, []},
      # Plugin system
      {Registry, keys: :unique, name: Cympho.PluginRegistry},
      Cympho.Plugins.Registry,
      {Cympho.Plugins.Supervisor, []},
      # Skill hot-reload for development
      {Cympho.Skills.HotReloader, []},
      # Rate limiting
      Cympho.RateLimiting.BroadcastDedup,
      Cympho.RateLimiting.IpRateLimiter,
      Cympho.EventStore,
      CymphoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cympho.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Adapters.Registry now registers builtins from its own init/1, so the
        # late-binding call here was a redundant double-registration.
        # Routine triggers are scheduled in a task so a transient failure
        # doesn't take down boot.
        Task.Supervisor.start_child(
          Cympho.TaskSupervisor,
          fn -> Cympho.RoutineTriggers.schedule_all_triggers() end,
          restart: :temporary
        )

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
end
