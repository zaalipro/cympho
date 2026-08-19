defmodule Cympho.Notifications.WebhookURL do
  @moduledoc false

  import Bitwise

  @connect_timeout 5_000
  @receive_timeout 15_000
  @request_timeout 15_000
  @max_response_header_count 100
  @max_response_header_bytes 64 * 1024

  defmodule Target do
    @moduledoc false

    @enforce_keys [:uri, :address, :addresses]
    defstruct [:uri, :address, :addresses]

    @type t :: %__MODULE__{
            uri: URI.t(),
            address: :inet.ip_address(),
            addresses: [:inet.ip_address()]
          }
  end

  @type address :: :inet.ip_address()
  @type resolver ::
          (String.t(), :inet | :inet6 -> {:ok, [address()]} | {:error, term()})
  @type requester ::
          (Target.t(), [{String.t(), String.t()}], iodata() ->
             {:ok, non_neg_integer()} | {:error, term()})

  @doc """
  Validates the part of a webhook URL that does not require network access.

  Webhooks must use HTTPS, include a DNS host or IP address, and must not contain
  user information or a fragment. Private and special-use literal IP addresses
  are rejected here; DNS names are resolved again immediately before each send.
  """
  @spec validate(term()) :: {:ok, URI.t()} | {:error, :invalid_url | :blocked_webhook_url}
  def validate(url) when is_binary(url) do
    with true <- url != "" and url == String.trim(url),
         {:ok, %URI{} = uri} <- URI.new(url),
         :ok <- validate_uri(uri),
         host = normalize_host(uri.host),
         :ok <- validate_host(host) do
      {:ok, %{uri | host: host}}
    else
      {:error, :blocked_webhook_url} = error -> error
      _other -> {:error, :invalid_url}
    end
  end

  def validate(_url), do: {:error, :invalid_url}

  @doc """
  Resolves every IPv4 and IPv6 address for a validated webhook URL.

  Resolution fails closed: an empty/error response, or any private or
  special-use address in either family, rejects the target. The returned target
  pins one of the validated tuples for the subsequent connection.
  """
  @spec resolve(term(), keyword()) ::
          {:ok, Target.t()}
          | {:error, :invalid_url | :blocked_webhook_url | :unresolvable_host}
  def resolve(url, opts \\ []) do
    with {:ok, uri} <- validate(url),
         {:ok, addresses} <- resolve_host(uri.host, opts),
         :ok <- validate_addresses(addresses) do
      {:ok, %Target{uri: uri, address: hd(addresses), addresses: addresses}}
    end
  end

  @doc """
  Posts to a validated, DNS-pinned webhook target.

  Redirects are deliberately not followed. This matches Finch's request
  behavior and ensures a redirect cannot introduce an unvalidated destination.
  """
  @spec post(term(), [{String.t(), String.t()}], iodata(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def post(url, headers, body, opts \\ []) do
    with {:ok, target} <- resolve(url, opts) do
      requester = Keyword.get(opts, :requester, &pinned_post/3)
      requester.(target, headers, body)
    end
  end

  defp validate_uri(%URI{
         scheme: "https",
         host: host,
         port: port,
         userinfo: nil,
         fragment: nil
       })
       when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 do
    :ok
  end

  defp validate_uri(%URI{scheme: "https", userinfo: userinfo}) when is_binary(userinfo),
    do: {:error, :blocked_webhook_url}

  defp validate_uri(_uri), do: {:error, :invalid_url}

  defp normalize_host(host) do
    host = String.downcase(host)

    if String.ends_with?(host, ".") and not String.ends_with?(host, "..") do
      binary_part(host, 0, byte_size(host) - 1)
    else
      host
    end
  end

  defp validate_host(host) do
    case parse_address(host) do
      {:ok, address} ->
        if public_address?(address), do: :ok, else: {:error, :blocked_webhook_url}

      {:error, _reason} ->
        if blocked_hostname?(host) do
          {:error, :blocked_webhook_url}
        else
          if dns_hostname?(host), do: :ok, else: {:error, :invalid_url}
        end
    end
  end

  defp blocked_hostname?(host) do
    host = String.downcase(host)

    host in ["localhost", "ip6-localhost", "ip6-loopback", "metadata"] or
      String.ends_with?(host, [".localhost", ".local", ".internal", ".home.arpa"]) or
      String.match?(host, ~r/^(?:(?:0x[0-9a-f]+|\d+)\.)*(?:0x[0-9a-f]+|\d+)$/i)
  end

  defp parse_address(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_strict_address()
  end

  defp dns_hostname?(host) do
    byte_size(host) <= 253 and
      host
      |> String.split(".")
      |> Enum.all?(&dns_label?/1)
  end

  defp dns_label?(label) do
    byte_size(label) in 1..63 and
      String.match?(label, ~r/^[a-zA-Z0-9](?:[a-zA-Z0-9-]*[a-zA-Z0-9])?$/)
  end

  defp resolve_host(host, opts) do
    case parse_address(host) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _reason} ->
        resolver = Keyword.get(opts, :resolver, &default_resolver/2)

        with {:ok, ipv4} <- resolve_family(resolver, host, :inet),
             {:ok, ipv6} <- resolve_family(resolver, host, :inet6),
             addresses = Enum.uniq(ipv4 ++ ipv6),
             false <- addresses == [] do
          {:ok, addresses}
        else
          _other -> {:error, :unresolvable_host}
        end
    end
  end

  defp default_resolver(host, family) do
    host
    |> String.to_charlist()
    |> :inet.getaddrs(family)
  end

  defp resolve_family(resolver, host, family) do
    case resolver.(host, family) do
      {:ok, addresses} when is_list(addresses) -> {:ok, addresses}
      {:error, :nxdomain} -> {:ok, []}
      _other -> {:error, :unresolvable_host}
    end
  end

  defp validate_addresses(addresses) do
    if Enum.all?(addresses, &public_address?/1),
      do: :ok,
      else: {:error, :blocked_webhook_url}
  end

  # IPv4-mapped IPv6 addresses are classified by their embedded IPv4 value.
  defp public_address?({0, 0, 0, 0, 0, 0xFFFF, high, low}) do
    public_address?({high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF})
  end

  # IPv4 special-purpose space from the IANA registry. These clauses cover
  # loopback, private/link-local, carrier-grade NAT, documentation,
  # benchmarking, multicast, and reserved/broadcast ranges.
  defp public_address?({first, _, _, _}) when first in [0, 10, 127] or first >= 224,
    do: false

  defp public_address?({100, second, _, _}) when second in 64..127, do: false
  defp public_address?({169, 254, _, _}), do: false
  defp public_address?({172, second, _, _}) when second in 16..31, do: false
  defp public_address?({192, 168, _, _}), do: false

  defp public_address?({192, second, third, _})
       when (second == 0 and third in [0, 2]) or
              (second == 31 and third == 196) or
              (second == 52 and third == 193) or
              (second == 88 and third == 99) or
              (second == 175 and third == 48),
       do: false

  defp public_address?({198, second, _, _}) when second in 18..19, do: false
  defp public_address?({198, 51, 100, _}), do: false
  defp public_address?({203, 0, 113, _}), do: false

  defp public_address?({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255,
       do: true

  # Only IPv6 global-unicast space is eligible. Exclude the special-purpose
  # ranges that sit inside 2000::/3 (IETF assignments, documentation, 6to4,
  # retired 6bone, and the current documentation prefix).
  defp public_address?({0x2001, second, _, _, _, _, _, _})
       when second <= 0x01FF or second == 0x0DB8,
       do: false

  defp public_address?({first, _, _, _, _, _, _, _}) when first in [0x2002, 0x3FFE],
    do: false

  defp public_address?({0x3FFF, second, _, _, _, _, _, _}) when second <= 0x0FFF,
    do: false

  defp public_address?({0x2620, 0x004F, 0x8000, _, _, _, _, _}), do: false

  defp public_address?({first, _, _, _, _, _, _, _}) when first in 0x2000..0x3FFF,
    do: true

  defp public_address?(_address), do: false

  defp pinned_post(%Target{} = target, headers, body) do
    deadline = System.monotonic_time(:millisecond) + @request_timeout

    connect_opts = [
      hostname: target.uri.host,
      mode: :passive,
      protocols: [:http1],
      transport_opts: transport_opts(target.address)
    ]

    case Mint.HTTP.connect(:https, target.address, target.uri.port, connect_opts) do
      {:ok, conn} -> send_pinned_request(conn, target, headers, body, deadline)
      {:error, reason} -> {:error, reason}
    end
  end

  defp transport_opts(address) when tuple_size(address) == 8,
    do: [timeout: @connect_timeout, inet6: true, inet4: false]

  defp transport_opts(_address), do: [timeout: @connect_timeout]

  defp send_pinned_request(conn, target, headers, body, deadline) do
    headers = [{"Host", host_header(target.uri)} | headers]

    result =
      case Mint.HTTP.request(conn, "POST", request_path(target.uri), headers, body) do
        {:ok, conn, request_ref} ->
          receive_response(
            conn,
            request_ref,
            %{status: nil, header_count: 0, header_bytes: 0},
            deadline
          )

        {:error, conn, reason} ->
          {{:error, reason}, conn}
      end

    {response, conn} = result
    _ = Mint.HTTP.close(conn)
    response
  end

  defp receive_response(conn, request_ref, state, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {{:error, :request_timeout}, conn}
    else
      recv_timeout = min(remaining, @receive_timeout)

      receive_response_chunk(conn, request_ref, state, deadline, recv_timeout)
    end
  end

  defp receive_response_chunk(conn, request_ref, state, deadline, recv_timeout) do
    case Mint.HTTP.recv(conn, 0, recv_timeout) do
      {:ok, conn, responses} ->
        case consume_responses(responses, request_ref, state) do
          {:done, nil} -> {{:error, :invalid_response}, conn}
          {:done, status} -> {{:ok, status}, conn}
          {:error, reason} -> {{:error, reason}, conn}
          {:cont, state} -> receive_response(conn, request_ref, state, deadline)
        end

      {:error, conn, reason, _responses} ->
        {{:error, reason}, conn}
    end
  end

  defp consume_responses(responses, request_ref, state) do
    Enum.reduce_while(responses, {:cont, state}, fn
      {:status, ^request_ref, status}, {:cont, current} when status in 100..199 ->
        {:cont, {:cont, %{current | status: status}}}

      {:status, ^request_ref, status}, _acc ->
        # Webhook delivery only needs the final status. Stop before retaining
        # the response body or application-level header list.
        {:halt, {:done, status}}

      {:headers, ^request_ref, headers}, {:cont, current} ->
        header_count = current.header_count + length(headers)
        header_bytes = current.header_bytes + response_header_bytes(headers)

        if header_count > @max_response_header_count or
             header_bytes > @max_response_header_bytes do
          {:halt, {:error, :response_headers_too_large}}
        else
          {:cont, {:cont, %{current | header_count: header_count, header_bytes: header_bytes}}}
        end

      {:done, ^request_ref}, {:cont, %{status: status}} ->
        final_status = if status in 100..199, do: nil, else: status
        {:halt, {:done, final_status}}

      {:error, ^request_ref, reason}, _acc ->
        {:halt, {:error, reason}}

      _response, acc ->
        {:cont, acc}
    end)
  end

  defp response_header_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, total ->
      total + IO.iodata_length(name) + IO.iodata_length(value) + 4
    end)
  end

  defp request_path(%URI{path: path, query: query}) when query in [nil, ""], do: path || "/"
  defp request_path(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp host_header(%URI{host: host, port: 443}), do: bracket_ipv6(host)
  defp host_header(%URI{host: host, port: port}), do: "#{bracket_ipv6(host)}:#{port}"

  defp bracket_ipv6(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end
end
