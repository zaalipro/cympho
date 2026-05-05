defmodule Cympho.Notifications.RetryWorker do
  @moduledoc """
  Retry worker for failed notification deliveries.
  Uses exponential backoff with jitter and event-type-aware max attempts.
  Records delivery failures to the dead-letter table on final retry exhaustion.
  """

  use GenServer

  alias Cympho.Notifications.Dispatcher
  alias Cympho.Notifications.Message
  alias Cympho.Notifications.NotificationDeliveryFailure

  @default_max_retries 3
  @critical_max_retries 10
  @base_delay 1_000
  @critical_event_types ~w(payment payment_refund payment_dispute payment_failed subscription_changed)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(_opts) do
    {:ok, %{}}
  end

  def max_attempts(%Message{event_type: event_type}) when event_type in @critical_event_types do
    @critical_max_retries
  end

  def max_attempts(_message), do: @default_max_retries

  @doc """
  Schedule a notification for retry with exponential backoff and jitter.
  """
  def schedule_retry(%Message{} = message, attempt) when attempt >= 1 do
    if attempt <= max_attempts(message) do
      GenServer.call(__MODULE__, {:schedule_retry, message, attempt})
    else
      {:error, :max_retries_exceeded}
    end
  end

  @doc """
  Retry a failed notification delivery.
  Records dead-letter entries on final retry failure.
  """
  def retry(%Message{} = message, attempt) do
    max = max_attempts(message)

    case Dispatcher.dispatch(message) do
      :ok ->
        :ok

      {:partial_failure, _} ->
        if attempt < max do
          schedule_retry(message, attempt + 1)
        else
          record_failure(message, attempt, "partial_delivery_failure")
          {:error, :max_retries_exceeded}
        end

      {:error, reason} ->
        if attempt < max do
          schedule_retry(message, attempt + 1)
        else
          record_failure(message, attempt, format_reason(reason))
          {:error, :max_retries_exceeded}
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
    case Dispatcher.dispatch(message) do
      :ok ->
        :ok

      {:partial_failure, _} ->
        maybe_schedule_next_retry(message, attempt)

      {:error, _} ->
        maybe_schedule_next_retry(message, attempt)
    end

    {:noreply, state}
  end

  defp maybe_schedule_next_retry(message, attempt) do
    if attempt >= max_attempts(message) do
      :logger.debug("RetryWorker: max retries exceeded")
    else
      delay = calculate_delay(attempt + 1)
      Process.send_after(self(), {:retry_notification, message, attempt + 1}, delay)
    end
  end

  defp calculate_delay(attempt) do
    base = (@base_delay * :math.pow(2, attempt - 1)) |> round()
    jitter = :rand.uniform(div(base, 2))
    base + jitter
  end

  defp record_failure(%Message{} = message, attempt, error_reason) do
    attrs = %{
      user_id: message.user_id,
      event_type: message.event_type || "unknown",
      channel_type: "unknown",
      payload: %{subject: message.subject, body: message.body},
      attempt: attempt,
      error_reason: error_reason,
      failed_at: DateTime.utc_now()
    }

    %NotificationDeliveryFailure{}
    |> NotificationDeliveryFailure.changeset(attrs)
    |> Cympho.Repo.insert()
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
