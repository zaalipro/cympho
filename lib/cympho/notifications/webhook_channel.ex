defmodule Cympho.Notifications.WebhookChannel do
  @moduledoc """
  Webhook notification channel.
  Delivers notifications by POSTing JSON to a configured webhook URL with HMAC-SHA256 signing.
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

      encoded = Jason.encode!(payload)
      headers = [{"Content-Type", "application/json"} | signature_headers(encoded, config)]

      case Finch.build(:post, url, headers, encoded)
           |> Finch.request(Cympho.Finch) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: status}} ->
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

  # HMAC-SHA256 signature headers
  defp signature_headers(payload, config) do
    secret = config[:hmac_secret] || config["hmac_secret"]

    if secret do
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
      [{"X-Cympho-Signature", "sha256=#{signature}"}]
    else
      []
    end
  end
end