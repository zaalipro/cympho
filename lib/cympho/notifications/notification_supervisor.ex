defmodule Cympho.Notifications.NotificationSupervisor do
  @moduledoc """
  Supervisor for the notification dispatch layer.

  Starts:
  - NotificationDispatcher GenServer (ETS-backed cache for user channel preferences)
  - NotificationRetryWorker GenServer (retry with exponential backoff)
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      Cympho.Notifications.Dispatcher,
      Cympho.Notifications.RetryWorker
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end