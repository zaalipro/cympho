defmodule Cympho.Notifications.WebhookChannel do
  @moduledoc """
  Webhook notification channel.
  Delivers notifications by POSTing JSON to a configured webhook URL.
  """

  alias Cympho.Notifications.Channel
  alias Cympho.Notifications.Message

  @behaviour Channel

  @impl Channel
  def deliver(%Message{} = message, config) do
    url = config[:url]

    if is_binary(url) and String.match?(url, ~r/^https?:\/\/.+/) do
      payload = %{
        subject: message.subject,
        body: message.body,
        user_id: message.user_id,
        metadata: message.metadata || %{},
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      case Finch.post(url, Jason.encode!(payload), [
             {"Content-Type", "application/json"}
           ]) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status}} ->
          {:error, {:http_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :invalid_url}
    end
  end

  @impl Channel
  def available?(config) do
    url = config[:url]
    is_binary(url) and url != "" and String.match?(url, ~r/^https?:\/\/.+/)
  end

  @impl Channel
  def type, do: :webhook
end