defmodule CymphoWeb.ClientIP do
  @moduledoc """
  Resolves the client address behind the configured trusted reverse proxies.

  Forwarded headers are honoured only when the immediate peer is a trusted
  proxy. `x-forwarded-for` is read right to left, skipping trusted proxy hops:
  only the entries appended by our own proxies can be trusted, while the
  leftmost entries are whatever the client chose to send.
  """

  alias CymphoWeb.Plugs.TransportSecurity

  @doc "Resolves the client address of a Plug connection."
  def from_conn(%Plug.Conn{remote_ip: peer_address, req_headers: headers}),
    do: resolve(peer_address, headers)

  @doc "Resolves the client address from the TCP peer and request headers."
  def resolve(peer_address, headers) do
    if TransportSecurity.trusted_peer?(peer_address) do
      case forwarded_address(headers) do
        {:ok, forwarded_address} -> forwarded_address
        :error -> peer_address
      end
    else
      peer_address
    end
  end

  defp forwarded_address(headers) when is_list(headers) do
    case header_value(headers, "x-forwarded-for") do
      nil -> parse_ip(header_value(headers, "x-real-ip"))
      value -> rightmost_untrusted(value)
    end
  end

  defp forwarded_address(_headers), do: :error

  defp rightmost_untrusted(value) do
    value
    |> String.split(",")
    |> Enum.reverse()
    |> Enum.reduce_while(:error, fn entry, :error -> classify_hop(entry) end)
  end

  # Trusted proxy hops are skipped; the first other address is the client.
  # A malformed entry stops the walk so the caller falls back to the peer.
  defp classify_hop(entry) do
    case parse_ip(entry) do
      {:ok, address} ->
        if TransportSecurity.trusted_peer?(address),
          do: {:cont, :error},
          else: {:halt, {:ok, address}}

      :error ->
        {:halt, :error}
    end
  end

  defp header_value(headers, name) do
    Enum.find_value(headers, fn
      {header, value} when is_binary(header) and is_binary(value) ->
        if String.downcase(header) == name, do: value

      _ ->
        nil
    end)
  end

  defp parse_ip(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip(_value), do: :error
end
