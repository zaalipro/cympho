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
      Cympho.Notifications.RetryWorker,
      CymphoWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Cympho.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CymphoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
