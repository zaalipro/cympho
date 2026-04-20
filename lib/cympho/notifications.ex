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

      {:error, _} = error ->
        Cympho.Notifications.RetryWorker.schedule_retry(message, 1)
    end
  end
end