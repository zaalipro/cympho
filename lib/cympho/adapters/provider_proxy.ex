defmodule Cympho.Adapters.ProviderProxy do
  @moduledoc """
  A short-lived, loopback-only proxy for OpenAI Responses API runs.

  The proxy gives an external runner a per-run capability instead of the real
  provider credential. It accepts only `POST /v1/responses`, then forwards the
  request to the configured HTTPS provider through `Cympho.Finch`. The caller
  that starts the proxy owns its linked Bandit server and must call `stop/1`
  after the run (the link also tears the server down if the owner exits).

  `base_url/1` and `capability/1` are the integration surface expected by
  adapters. For example, they can be supplied to a Responses API client as its
  base URL and API key respectively.
  """

  alias __MODULE__.ProxyPlug

  @default_max_request_bytes 8 * 1_024 * 1_024
  @default_max_response_bytes 32 * 1_024 * 1_024
  @absolute_max_request_bytes 32 * 1_024 * 1_024
  @absolute_max_response_bytes 128 * 1_024 * 1_024
  @default_timeout_ms 120_000
  @default_receive_timeout_ms 30_000
  @default_read_timeout_ms 15_000
  @maximum_timeout_ms 600_000
  @shutdown_timeout_ms 5_000
  @stop_timeout_ms @shutdown_timeout_ms + 1_000

  @enforce_keys [:server_pid, :base_url, :capability]
  @derive {Inspect, only: [:base_url]}
  defstruct [:server_pid, :base_url, :capability]

  @opaque t :: %__MODULE__{
            server_pid: pid(),
            base_url: String.t(),
            capability: String.t()
          }

  @typedoc "Options accepted by `start/1`."
  @type option ::
          {:upstream_base_url, String.t()}
          | {:api_key, String.t()}
          | {:max_request_bytes, pos_integer()}
          | {:max_response_bytes, pos_integer()}
          | {:timeout_ms, pos_integer()}
          | {:receive_timeout_ms, pos_integer()}
          | {:read_timeout_ms, pos_integer()}

  @doc """
  Starts a proxy on a kernel-selected port bound to `127.0.0.1`.

  `:upstream_base_url` and `:api_key` are required. The upstream base must use
  HTTPS and must not contain userinfo, a query, or a fragment. Optional limits
  are bounded by the module's safety ceilings.
  """
  @spec start([option()]) :: {:ok, t()} | {:error, term()}
  def start(opts) when is_list(opts) do
    with {:ok, config} <- build_config(opts),
         {capability, server_config} <- Map.pop(config, :capability),
         {:ok, server_pid} <- start_server(server_config) do
      proxy_from_server(server_pid, capability)
    end
  end

  @doc "Returns the loopback OpenAI base URL (ending in `/v1`)."
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{base_url: base_url}), do: base_url

  @doc "Returns the per-run Bearer capability expected by the proxy."
  @spec capability(t()) :: String.t()
  def capability(%__MODULE__{capability: capability}), do: capability

  @doc "Stops the proxy and drains active connections for a short bounded period."
  @spec stop(t(), timeout()) :: :ok
  def stop(%__MODULE__{server_pid: server_pid}, timeout \\ @stop_timeout_ms)
      when is_integer(timeout) and timeout > 0 do
    if Process.alive?(server_pid) do
      Supervisor.stop(server_pid, :normal, timeout)
    else
      :ok
    end
  catch
    :exit, {:noproc, _} -> :ok
  end

  defp build_config(opts) do
    with {:ok, upstream_base_url} <- fetch_binary(opts, :upstream_base_url),
         {:ok, upstream_url} <- responses_url(upstream_base_url),
         {:ok, api_key} <- fetch_api_key(opts),
         {:ok, max_request_bytes} <-
           bounded_size(
             opts,
             :max_request_bytes,
             @default_max_request_bytes,
             @absolute_max_request_bytes
           ),
         {:ok, max_response_bytes} <-
           bounded_size(
             opts,
             :max_response_bytes,
             @default_max_response_bytes,
             @absolute_max_response_bytes
           ),
         {:ok, timeout_ms} <- bounded_timeout(opts, :timeout_ms, @default_timeout_ms),
         {:ok, receive_timeout_ms} <-
           bounded_timeout(opts, :receive_timeout_ms, @default_receive_timeout_ms),
         {:ok, read_timeout_ms} <-
           bounded_timeout(opts, :read_timeout_ms, @default_read_timeout_ms) do
      capability = random_capability()

      {:ok,
       %{
         upstream_url: upstream_url,
         upstream_authorization: "Bearer " <> api_key,
         capability: capability,
         capability_digest: digest(capability),
         max_request_bytes: max_request_bytes,
         max_response_bytes: max_response_bytes,
         timeout_ms: timeout_ms,
         receive_timeout_ms: receive_timeout_ms,
         read_timeout_ms: read_timeout_ms
       }}
    end
  end

  defp fetch_binary(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} when is_binary(value) -> {:ok, value}
      {:ok, _value} -> {:error, {:invalid_option, key}}
      :error -> {:error, {:missing_option, key}}
    end
  end

  defp fetch_api_key(opts) do
    with {:ok, api_key} <- fetch_binary(opts, :api_key),
         true <- String.trim(api_key) != "",
         false <- String.contains?(api_key, ["\r", "\n", "\0"]) do
      {:ok, api_key}
    else
      _ -> {:error, {:invalid_option, :api_key}}
    end
  end

  defp bounded_size(opts, key, default, maximum) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and value <= maximum do
      {:ok, value}
    else
      {:error, {:invalid_option, key}}
    end
  end

  defp bounded_timeout(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 and value <= @maximum_timeout_ms do
      {:ok, value}
    else
      {:error, {:invalid_option, key}}
    end
  end

  defp responses_url(base_url) do
    with {:ok, uri} <- parse_https_base(base_url),
         {:ok, base_path} <- validate_base_path(uri.path) do
      {:ok, URI.to_string(%{uri | path: base_path <> "/responses"})}
    end
  end

  defp parse_https_base(base_url) do
    with {:ok, uri} <- URI.new(String.trim(base_url)),
         true <- uri.scheme == "https",
         true <- valid_host?(uri.host),
         true <- is_integer(uri.port) and uri.port > 0 and uri.port <= 65_535,
         true <- is_nil(uri.userinfo),
         true <- is_nil(uri.query),
         true <- is_nil(uri.fragment) do
      {:ok, uri}
    else
      _other -> {:error, {:invalid_option, :upstream_base_url}}
    end
  rescue
    _ -> {:error, {:invalid_option, :upstream_base_url}}
  end

  defp validate_base_path(nil), do: {:ok, ""}
  defp validate_base_path("/"), do: {:ok, ""}

  defp validate_base_path(path) when is_binary(path) do
    path = String.trim_trailing(path, "/")
    segments = String.split(path, "/", trim: false)

    cond do
      not String.starts_with?(path, "/") ->
        {:error, {:invalid_option, :upstream_base_url}}

      Enum.any?(tl(segments), &unsafe_path_segment?/1) ->
        {:error, {:invalid_option, :upstream_base_url}}

      true ->
        {:ok, path}
    end
  end

  defp unsafe_path_segment?(""), do: true

  defp unsafe_path_segment?(segment) do
    decoded = URI.decode(segment)

    decoded in [".", ".."] or String.contains?(decoded, ["/", "\\", "\0"])
  rescue
    _ -> true
  end

  defp valid_host?(host) do
    is_binary(host) and String.trim(host) != "" and
      not String.contains?(host, ["%", "/", "\\", "@", " ", "\t", "\r", "\n", "\0"])
  end

  defp random_capability do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)

  defp start_server(config) do
    Bandit.start_link(
      plug: {ProxyPlug, config},
      scheme: :http,
      ip: {127, 0, 0, 1},
      port: 0,
      startup_log: false,
      http_options: [
        compress: false,
        log_exceptions_with_status_codes: [],
        log_protocol_errors: false,
        log_client_closures: false
      ],
      http_1_options: [
        max_request_line_length: 2_048,
        max_header_length: 16_384,
        max_header_count: 64
      ],
      http_2_options: [enabled: false],
      websocket_options: [enabled: false],
      thousand_island_options: [
        num_acceptors: 2,
        num_connections: 16,
        read_timeout: config.read_timeout_ms,
        shutdown_timeout: @shutdown_timeout_ms,
        silent_terminate_on_error: true
      ]
    )
  end

  defp proxy_from_server(server_pid, capability) do
    case ThousandIsland.listener_info(server_pid) do
      {:ok, {{127, 0, 0, 1}, port}} ->
        {:ok,
         %__MODULE__{
           server_pid: server_pid,
           base_url: "http://127.0.0.1:#{port}/v1",
           capability: capability
         }}

      _other ->
        _ = Supervisor.stop(server_pid, :normal, @stop_timeout_ms)
        {:error, :listener_not_loopback}
    end
  end

  defmodule ProxyPlug do
    @moduledoc false

    @behaviour Plug

    import Plug.Conn

    @hop_by_hop_headers MapSet.new([
                          "connection",
                          "keep-alive",
                          "proxy-authenticate",
                          "proxy-authorization",
                          "proxy-connection",
                          "te",
                          "trailer",
                          "transfer-encoding",
                          "upgrade"
                        ])
    @request_only_headers MapSet.new(["authorization", "content-length", "host"])
    @response_only_headers MapSet.new(["content-length"])

    @impl Plug
    def init(config), do: config

    @impl Plug
    def call(
          %Plug.Conn{method: "POST", request_path: "/v1/responses", query_string: ""} = conn,
          config
        ) do
      if authorized?(conn, config.capability_digest) do
        proxy(conn, config)
      else
        error_response(conn, 401, "unauthorized")
      end
    end

    def call(%Plug.Conn{request_path: "/v1/responses", query_string: ""} = conn, _config) do
      conn
      |> put_resp_header("allow", "POST")
      |> error_response(405, "method not allowed")
    end

    def call(conn, _config), do: error_response(conn, 404, "not found")

    defp authorized?(conn, expected_digest) do
      case get_req_header(conn, "authorization") do
        ["Bearer " <> capability] when capability != "" ->
          Plug.Crypto.secure_compare(:crypto.hash(:sha256, capability), expected_digest)

        _other ->
          false
      end
    end

    defp proxy(conn, config) do
      case read_bounded_body(conn, config.max_request_bytes, config.read_timeout_ms) do
        {:ok, body, conn} -> forward(conn, body, config)
        {:error, :too_large, conn} -> error_response(conn, 413, "request body too large")
        {:error, :timeout, conn} -> error_response(conn, 408, "request body timeout")
        {:error, _reason, conn} -> error_response(conn, 400, "invalid request body")
      end
    end

    defp read_bounded_body(conn, maximum, read_timeout) do
      do_read_body(conn, maximum, monotonic_ms() + read_timeout, [], 0)
    end

    defp do_read_body(conn, maximum, deadline_ms, chunks, size) do
      remaining_ms = deadline_ms - monotonic_ms()

      if remaining_ms <= 0 do
        {:error, :timeout, conn}
      else
        read_body_chunk(conn, maximum, deadline_ms, remaining_ms, chunks, size)
      end
    end

    defp read_body_chunk(conn, maximum, deadline_ms, remaining_ms, chunks, size) do
      read_options = [
        length: maximum + 1,
        read_length: min(maximum + 1, 1_000_000),
        read_timeout: remaining_ms
      ]

      case read_body(conn, read_options) do
        {status, chunk, conn} when status in [:ok, :more] ->
          consume_body_chunk(status, chunk, conn, maximum, deadline_ms, chunks, size)

        {:error, :timeout} ->
          {:error, :timeout, conn}

        {:error, reason} ->
          {:error, reason, conn}
      end
    end

    defp consume_body_chunk(status, chunk, conn, maximum, deadline_ms, chunks, size) do
      new_size = size + byte_size(chunk)

      cond do
        new_size > maximum ->
          {:error, :too_large, conn}

        status == :ok ->
          {:ok, chunks |> Enum.reverse([chunk]) |> IO.iodata_to_binary(), conn}

        true ->
          do_read_body(conn, maximum, deadline_ms, [chunk | chunks], new_size)
      end
    end

    defp forward(conn, body, config) do
      Process.put(stream_started_key(), false)

      request_headers =
        conn.req_headers
        |> strip_headers(@request_only_headers)
        |> List.insert_at(0, {"authorization", config.upstream_authorization})

      request = Finch.build(:post, config.upstream_url, request_headers, body)

      initial = %{
        conn: conn,
        status: nil,
        headers: [],
        started?: false,
        response_bytes: 0,
        failure: nil,
        deadline_ms: monotonic_ms() + config.timeout_ms,
        max_response_bytes: config.max_response_bytes
      }

      result =
        Finch.stream_while(request, Cympho.Finch, initial, &handle_upstream_event/2,
          pool_timeout: min(config.timeout_ms, 5_000),
          receive_timeout: config.receive_timeout_ms,
          request_timeout: config.timeout_ms
        )
        |> case do
          {:error, reason} -> {:error, reason, initial}
          result -> result
        end

      finish(result)
    rescue
      _error -> recover_from_stream_failure(conn)
    catch
      :exit, _reason -> recover_from_stream_failure(conn)
      _kind, _reason -> recover_from_stream_failure(conn)
    after
      Process.delete(stream_started_key())
    end

    defp handle_upstream_event(_event, %{failure: failure} = state) when not is_nil(failure) do
      {:halt, state}
    end

    defp handle_upstream_event(event, state) do
      if state.deadline_ms <= monotonic_ms() do
        {:halt, %{state | failure: :timeout}}
      else
        handle_fresh_upstream_event(event, state)
      end
    end

    defp handle_fresh_upstream_event({:status, status}, state)
         when is_integer(status) and status >= 300 and status <= 399 do
      {:halt, %{state | failure: :redirect}}
    end

    defp handle_fresh_upstream_event({:status, status}, state)
         when is_integer(status) and status >= 200 and status <= 599 do
      {:cont, %{state | status: status}}
    end

    defp handle_fresh_upstream_event({:status, _status}, state) do
      {:halt, %{state | failure: :bad_gateway}}
    end

    defp handle_fresh_upstream_event({:headers, headers}, state) when is_list(headers) do
      {:cont, %{state | headers: strip_headers(headers, @response_only_headers)}}
    end

    defp handle_fresh_upstream_event({:data, _chunk}, %{status: nil} = state) do
      {:halt, %{state | failure: :bad_gateway}}
    end

    defp handle_fresh_upstream_event({:data, chunk}, state) when is_binary(chunk) do
      new_size = state.response_bytes + byte_size(chunk)

      if new_size > state.max_response_bytes do
        {:halt, %{state | failure: :response_too_large}}
      else
        state = ensure_response_started(state)

        case chunk(state.conn, chunk) do
          {:ok, conn} ->
            {:cont, %{state | conn: conn, response_bytes: new_size}}

          {:error, _reason} ->
            {:halt, %{state | failure: :client_closed}}
        end
      end
    end

    defp handle_fresh_upstream_event({:trailers, _headers}, state), do: {:cont, state}

    defp handle_fresh_upstream_event(_event, state),
      do: {:halt, %{state | failure: :bad_gateway}}

    defp ensure_response_started(%{started?: true} = state), do: state

    defp ensure_response_started(state) do
      conn =
        state.conn
        |> prepend_resp_headers(state.headers)
        |> send_chunked(state.status || 502)

      Process.put(stream_started_key(), true)
      %{state | conn: conn, started?: true}
    end

    defp finish({:ok, %{failure: nil, started?: true} = state}), do: state.conn

    defp finish({:ok, %{failure: nil} = state}) do
      state.conn
      |> prepend_resp_headers(state.headers)
      |> send_resp(state.status || 502, "")
    end

    defp finish({:ok, %{failure: :client_closed} = state}), do: state.conn

    defp finish({:ok, %{failure: failure, started?: true}})
         when failure in [:timeout, :response_too_large, :bad_gateway] do
      abort_started_stream()
    end

    defp finish({:ok, %{failure: :timeout} = state}) do
      error_response(state.conn, 504, "provider request timeout")
    end

    defp finish({:ok, %{failure: :response_too_large} = state}) do
      error_response(state.conn, 502, "provider response too large")
    end

    defp finish({:ok, %{failure: :redirect} = state}) do
      error_response(state.conn, 502, "provider redirect rejected")
    end

    defp finish({:ok, state}), do: error_response(state.conn, 502, "provider request failed")

    defp finish({:error, %{reason: reason}, state}) when reason in [:timeout, :request_timeout] do
      finish_transport_error(state, 504, "provider request timeout")
    end

    defp finish({:error, _reason, state}) do
      finish_transport_error(state, 502, "provider request failed")
    end

    defp finish_transport_error(%{started?: true}, _status, _message), do: abort_started_stream()

    defp finish_transport_error(state, status, message) do
      error_response(state.conn, status, message)
    end

    defp strip_headers(headers, additional) do
      connection_headers = connection_header_names(headers)

      blocked =
        @hop_by_hop_headers |> MapSet.union(additional) |> MapSet.union(connection_headers)

      Enum.reduce(headers, [], fn
        {name, value}, acc when is_binary(name) and is_binary(value) ->
          normalized_name = String.downcase(name)

          if MapSet.member?(blocked, normalized_name) or
               not valid_header?(normalized_name, value) do
            acc
          else
            [{normalized_name, value} | acc]
          end

        _other, acc ->
          acc
      end)
      |> Enum.reverse()
    end

    defp connection_header_names(headers) do
      headers
      |> Enum.flat_map(fn
        {name, value} when is_binary(name) and is_binary(value) ->
          if String.downcase(name) == "connection" do
            String.split(value, ",", trim: true)
          else
            []
          end

        _other ->
          []
      end)
      |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
      |> MapSet.new()
    end

    defp valid_header?(name, value) do
      name != "" and not String.contains?(name, [":", "\r", "\n", "\0"]) and
        not String.contains?(value, ["\r", "\n", "\0"])
    end

    defp recover_from_stream_failure(conn) do
      if Process.get(stream_started_key(), false) do
        abort_started_stream()
      else
        error_response(conn, 502, "provider request failed")
      end
    end

    defp abort_started_stream, do: throw(:cympho_provider_proxy_stream_aborted)

    defp stream_started_key, do: {__MODULE__, :stream_started}

    defp error_response(conn, status, message) do
      conn
      |> put_resp_content_type("text/plain")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, message)
      |> halt()
    end

    defp monotonic_ms, do: System.monotonic_time(:millisecond)
  end
end
