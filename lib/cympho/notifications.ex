defmodule Cympho.Notifications do
  @moduledoc """
  The Notifications context for dispatching messages through multiple channels.
  """

  alias Cympho.Notifications.{Dispatcher, Message}

  @doc """
  Send a notification to a user.
  """
  def notify(subject, body, user_id, metadata \\ %{}) do
    message = Message.new(subject, body, user_id, metadata)
    Dispatcher.dispatch(message)
  end

  @doc """
  Send a notification asynchronously.
  """
  def notify_async(subject, body, user_id, metadata \\ %{}) do
    message = Message.new(subject, body, user_id, metadata)
    Dispatcher.dispatch_async(message)
  end

  @doc """
  Send a test ping to a webhook URL.
  """
  def test_webhook(url) do
    payload = %{
      event: "test_ping",
      message: "Test notification from Cympho",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    encoded = Jason.encode!(payload)
    headers = [{"Content-Type", "application/json"}]

    case Finch.post(url, encoded, headers) do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, status}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Send a notification with retry support for failed deliveries.
  """
  def notify_with_retry(subject, body, user_id, metadata \\ %{}) do
    message = Message.new(subject, body, user_id, metadata)

    case Dispatcher.dispatch(message) do
      :ok ->
        :ok

      {:partial_failure, _} ->
        Cympho.Notifications.RetryWorker.schedule_retry(message, 1)

      {:error, :user_not_found} = error ->
        error

      {:error, _} = _error ->
        Cympho.Notifications.RetryWorker.schedule_retry(message, 1)
    end
  end
end