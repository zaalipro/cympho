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
    url = config_value(config, :url)

    cond do
      not (is_binary(url) and String.match?(url, ~r/^https?:\/\/.+/)) ->
        {:error, :invalid_url}

      blocked_webhook_url?(url) ->
        {:error, :blocked_webhook_url}

      true ->
        payload = %{
          event_type: event_type(message),
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
    end
  end

  @impl Channel
  def available?(config) do
    url = config_value(config, :url)
    is_binary(url) and url != "" and String.match?(url, ~r/^https?:\/\/.+/)
  end

  @impl Channel
  def type, do: :webhook

  # HMAC-SHA256 signature headers
  defp signature_headers(payload, config) do
    secret = config_value(config, :hmac_secret)

    if secret do
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
      [{"X-Cympho-Signature", "sha256=#{signature}"}]
    else
      []
    end
  end

  defp event_type(%Message{event_type: type}) when is_binary(type) and type != "", do: type
  defp event_type(%Message{metadata: %{type: type}}) when is_binary(type), do: type
  defp event_type(%Message{metadata: %{"type" => type}}) when is_binary(type), do: type
  defp event_type(_message), do: nil

  defp config_value(config, key) when is_map(config) and is_atom(key) do
    Map.get(config, key) || Map.get(config, Atom.to_string(key))
  end

  defp config_value(_config, _key), do: nil

  defp blocked_webhook_url?(url) do
    uri = URI.parse(url)
    host = uri.host

    cond do
      not is_binary(host) or host == "" -> true
      present_userinfo?(uri.userinfo) -> true
      metadata_hostname?(host) -> true
      loopback_hostname?(host) -> true
      blocked_literal_ip?(host) -> true
      true -> false
    end
  end

  defp present_userinfo?(nil), do: false
  defp present_userinfo?(""), do: false
  defp present_userinfo?(_userinfo), do: true

  defp metadata_hostname?(host) do
    host = String.downcase(host)

    host in ["metadata.google.internal", "metadata", "169.254.169.254"] or
      host == "fd00:ec2::254"
  end

  defp loopback_hostname?(host) do
    String.downcase(host) in ["localhost", "ip6-localhost", "ip6-loopback"]
  end

  defp blocked_literal_ip?(host) do
    host
    |> strip_ip_brackets()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> blocked_ip?(ip)
      {:error, _} -> false
    end
  end

  defp strip_ip_brackets("[" <> rest) do
    String.trim_trailing(rest, "]")
  end

  defp strip_ip_brackets(host), do: host

  defp blocked_ip?({127, _, _, _}), do: true
  defp blocked_ip?({169, 254, _, _}), do: true
  defp blocked_ip?({10, _, _, _}), do: true
  defp blocked_ip?({192, 168, _, _}), do: true
  defp blocked_ip?({172, second, _, _}) when second in 16..31, do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp blocked_ip?({0, 0, 0, 0, 0, 65535, high, low}), do: blocked_ip?(mapped_ipv4(high, low))
  defp blocked_ip?({0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254}), do: true

  defp blocked_ip?({first, _, _, _, _, _, _, _}) when first >= 0xFE80 and first <= 0xFEBF,
    do: true

  defp blocked_ip?(_ip), do: false

  defp mapped_ipv4(high, low) do
    {div(high, 256), rem(high, 256), div(low, 256), rem(low, 256)}
  end
end
