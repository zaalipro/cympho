defmodule Cympho.Notifications.RetryWorker do
  @moduledoc """
  Retry worker for failed notification deliveries.
  Uses exponential backoff with a maximum number of retries.
  """

  use GenServer

  alias Cympho.Notifications.Dispatcher
  alias Cympho.Notifications.Message

  @max_retries 3
  @base_delay 1_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    {:ok, %{}}
  end

  @doc """
  Schedule a notification for retry with exponential backoff.
  Runs on the RetryWorker GenServer to ensure messages are delivered correctly.
  """
  def schedule_retry(%Message{} = message, attempt \\ 1) when attempt <= @max_retries do
    GenServer.call(__MODULE__, {:schedule_retry, message, attempt})
  end

  @doc """
  Retry a failed notification delivery.
  """
  def retry(%Message{} = message, attempt) do
    case Dispatcher.dispatch(message) do
      :ok ->
        :ok

      {:partial_failure, _} ->
        if attempt < @max_retries do
          schedule_retry(message, attempt + 1)
        else
          {:error, :max_retries_exceeded}
        end

      {:error, _} = error ->
        if attempt < @max_retries do
          schedule_retry(message, attempt + 1)
        else
          error
        end
    end
  end

  @impl GenServer
  def handle_call({:schedule_retry, message, attempt}, _from, state) do
    delay = calculate_delay(attempt)

    Process.send_after(
      self(),
      {:retry_notification, message, attempt},
      delay
    )

    {:reply, {:ok, attempt}, state}
  end

  @impl GenServer
  def handle_info({:retry_notification, message, attempt}, state) do
    retry(message, attempt)
    {:noreply, state}
  end

  defp calculate_delay(attempt) do
    @base_delay * :math.pow(2, attempt - 1) |> round()
  end
end