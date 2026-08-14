defmodule Cympho.Adapters.HttpAdapter do
  @moduledoc """
  Generic HTTP webhook adapter.

  Runs agents by making HTTP requests to external endpoints.
  """

  @behaviour Cympho.Adapters.Adapter

  import Bitwise

  alias Cympho.Adapters.RuntimeTimeout

  @default_timeout 30_000
  @max_timeout 3_600_000
  @blocked_url_message "url host is not allowed"
  @metadata_hosts ~w(metadata.google.internal 169.254.169.254)
  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()

    worker =
      spawn(fn ->
        try do
          do_run(session_id, issue, agent_id, recipient_pid, opts)
        after
          Cympho.AdapterSessions.unregister(session_id)
        end
      end)

    Cympho.AdapterSessions.register(session_id, worker)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, opts) do
    send(recipient_pid, {:session_started, session_id})

    config = opts[:config] || %{}

    result =
      Cympho.AdapterSessions.run_cancellable(session_id, fn ->
        call_http_endpoint(issue, agent_id, config, opts)
      end)

    case result do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp call_http_endpoint(issue, agent_id, config, opts) do
    url = config[:url] || config["url"]
    method = config[:method] || config["method"] || :post
    headers = build_headers(config)
    timeout = RuntimeTimeout.resolve(config, default_ms: @default_timeout)
    callback_url = config[:callback_url] || config["callback_url"]

    if is_nil(url) or url == "" do
      {:error, :no_url_configured}
    else
      payload = build_payload(issue, agent_id, config)
      attach_payload_telemetry(opts, payload)

      case make_http_request(method, url, headers, payload, timeout) do
        {:ok, response} ->
          handle_response({:ok, response}, callback_url, config)

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

  defp attach_payload_telemetry(opts, payload) do
    Cympho.PromptTelemetry.attach_to_run(opts, encode_payload(payload), %{
      "adapter" => "http",
      "source" => "http_payload"
    })
  end

  defp encode_payload(payload) do
    Jason.encode!(payload)
  rescue
    _ -> inspect(payload)
  end

  defp build_headers(config) do
    base_headers = config[:headers] || config["headers"] || %{}
    auth_token = config[:auth_token] || config["auth_token"]

    headers =
      if auth_token do
        Map.put(base_headers, "authorization", "Bearer #{auth_token}")
      else
        base_headers
      end

    # Ensure content-type is set
    if not Map.has_key?(headers, "content-type") and not Map.has_key?(headers, "Content-Type") do
      Map.put(headers, "content-type", "application/json")
    else
      headers
    end
  end

  defp handle_response({:ok, data}, nil, _config), do: {:ok, data}
  defp handle_response({:ok, data}, _callback_url, _config), do: {:ok, data}

  defp build_payload(issue, agent_id, config) do
    base_payload = %{
      issue_id: issue.id,
      issue_title: issue.title,
      issue_description: issue.description,
      agent_id: agent_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Merge with custom payload template if provided
    template = config[:payload_template] || config["payload_template"]

    if template do
      deep_merge(base_payload, template)
    else
      base_payload
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, v1, v2 ->
      if is_map(v1) and is_map(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end

  # 5 MiB cap on response body. A misbehaving or malicious upstream that
  # streams an unbounded payload would otherwise OOM the worker; we abort
  # the streaming accumulation and return :response_too_large.
  @max_response_bytes 5 * 1024 * 1024

  defp make_http_request(method, url, headers, payload, timeout) do
    with :ok <- validate_public_url(url) do
      method_atom = normalize_method(method)
      headers_list = normalize_headers(headers)

      encoded_payload = Jason.encode!(payload)
      req = Finch.build(method_atom, url, headers_list, encoded_payload)
      stream_to_acc(req, timeout)
    end
  end

  defp stream_to_acc(req, timeout) do
    init = %{status: nil, headers: [], body: [], size: 0, overflow: false}

    fun = fn
      {:status, s}, acc ->
        %{acc | status: s}

      {:headers, hs}, acc ->
        %{acc | headers: hs}

      {:data, _chunk}, %{overflow: true} = acc ->
        acc

      {:data, chunk}, acc ->
        new_size = acc.size + byte_size(chunk)

        if new_size > @max_response_bytes do
          %{acc | overflow: true}
        else
          %{acc | body: [chunk | acc.body], size: new_size}
        end
    end

    case Finch.stream(req, Cympho.Finch, init, fun, receive_timeout: timeout) do
      {:ok, %{overflow: true}} ->
        {:error, :response_too_large}

      {:ok, %{status: status, headers: hs, body: chunks}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, %{status: status, headers: hs, body: body}}

      {:error, %Finch.Error{} = error} ->
        {:error, {:finch_error, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:request_error, reason}}
    end
  end

  defp normalize_method(method) when is_atom(method), do: method

  defp normalize_method(method) when is_binary(method) do
    method |> String.downcase() |> String.to_existing_atom()
  rescue
    ArgumentError -> :post
  end

  defp normalize_headers(headers) when is_list(headers), do: headers

  defp normalize_headers(headers) when is_map(headers) do
    Enum.map(headers, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp normalize_headers(_), do: []

  @impl true
  def health_check(config) do
    url = config[:url] || config["url"]
    health_endpoint = config[:health_endpoint] || config["health_endpoint"]
    headers = normalize_headers(config[:headers] || config["headers"] || [])
    timeout = config[:health_timeout] || config["health_timeout"] || 5000

    cond do
      is_nil(url) or url == "" ->
        %{status: :unhealthy, message: "No URL configured", checked_at: DateTime.utc_now()}

      true ->
        check_url = if health_endpoint, do: health_endpoint, else: url
        probe_headers = probe_headers(headers)

        case validate_public_url(check_url) do
          :ok ->
            do_health_check(check_url, probe_headers, timeout)

          {:error, reason} ->
            %{
              status: :unhealthy,
              message: reason,
              checked_at: DateTime.utc_now()
            }
        end
    end
  end

  defp probe_headers(headers) do
    headers
    |> normalize_headers()
    |> Enum.reject(fn {key, _value} ->
      String.downcase(to_string(key)) in ["authorization", "auth_token"]
    end)
  end

  defp do_health_check(url, headers, timeout) do
    with :ok <- validate_public_url(url) do
      do_public_health_check(url, headers, timeout)
    else
      {:error, reason} ->
        %{
          status: :unhealthy,
          message: reason,
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp do_public_health_check(url, headers, timeout) do
    # Try HEAD first, fall back to GET
    req = Finch.build(:head, url, headers)

    case Finch.request(req, Cympho.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        %{
          status: :healthy,
          message: "Endpoint accessible (HEAD #{status})",
          checked_at: DateTime.utc_now()
        }

      {:ok, %Finch.Response{status: status}} when status in 300..399 ->
        # Redirect - try GET
        do_get_health_check(url, headers, timeout)

      {:ok, %Finch.Response{status: status}} ->
        %{
          status: :unhealthy,
          message: "Endpoint returned error status (HEAD #{status})",
          checked_at: DateTime.utc_now()
        }

      {:error, %Finch.Error{}} ->
        do_get_health_check(url, headers, timeout)

      {:error, reason} ->
        %{
          status: :unhealthy,
          message: "Health check failed: #{inspect(reason)}",
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp do_get_health_check(url, headers, timeout) do
    with :ok <- validate_public_url(url) do
      do_public_get_health_check(url, headers, timeout)
    else
      {:error, reason} ->
        %{
          status: :unhealthy,
          message: reason,
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp do_public_get_health_check(url, headers, timeout) do
    req = Finch.build(:get, url, headers)

    case Finch.request(req, Cympho.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status}} when status in 200..299 ->
        %{
          status: :healthy,
          message: "Endpoint accessible (GET #{status})",
          checked_at: DateTime.utc_now()
        }

      {:ok, %Finch.Response{status: status}} ->
        %{
          status: :unhealthy,
          message: "Endpoint returned error status (GET #{status})",
          checked_at: DateTime.utc_now()
        }

      {:error, %Finch.Error{} = error} ->
        %{
          status: :unhealthy,
          message: "Request failed: #{Exception.message(error)}",
          checked_at: DateTime.utc_now()
        }

      {:error, reason} ->
        %{
          status: :unhealthy,
          message: "Request failed: #{inspect(reason)}",
          checked_at: DateTime.utc_now()
        }
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :url,
        type: :string,
        required: true,
        default: nil,
        description: "HTTP endpoint URL"
      },
      %{
        key: :method,
        type: :string,
        required: false,
        default: "post",
        description: "HTTP method (get, post, put, patch, delete)"
      },
      %{
        key: :headers,
        type: :map,
        required: false,
        default: %{},
        description: "HTTP headers (e.g., Authorization, Content-Type)"
      },
      %{
        key: :auth_token,
        type: :string,
        required: false,
        default: nil,
        description: "Bearer token for Authorization header (overrides headers['Authorization'])"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: @default_timeout,
        description:
          "Request timeout in milliseconds. Prefer timeout_sec for human-entered values."
      },
      %{
        key: :timeout_sec,
        type: :integer,
        required: false,
        default: div(@default_timeout, 1_000),
        description: "Request timeout in seconds; conflicts with timeout/timeout_ms are rejected."
      },
      %{
        key: :payload_template,
        type: :map,
        required: false,
        default: nil,
        description: "Custom payload template to merge with default"
      },
      %{
        key: :health_endpoint,
        type: :string,
        required: false,
        default: nil,
        description: "Optional health check endpoint (defaults to main URL)"
      },
      %{
        key: :health_timeout,
        type: :integer,
        required: false,
        default: 5000,
        description: "Health check timeout in milliseconds"
      },
      %{
        key: :callback_url,
        type: :string,
        required: false,
        default: nil,
        description: "Callback URL for async result delivery"
      },
      %{
        key: :callback_timeout,
        type: :integer,
        required: false,
        default: 60_000,
        description: "How long to poll for callback result (milliseconds)"
      }
    ]
  end

  @impl true
  def name, do: "HTTP Webhook"

  @impl true
  def type, do: :http

  @impl true
  def available? do
    # HTTP adapter is always available
    true
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_url(config["url"] || config[:url]),
         :ok <- validate_method(config["method"] || config[:method]),
         :ok <- validate_headers(config["headers"] || config[:headers]),
         :ok <- validate_timeout(config),
         :ok <- validate_auth_token(config["auth_token"] || config[:auth_token]),
         :ok <- validate_callback_url(config["callback_url"] || config[:callback_url]),
         :ok <- validate_health_endpoint(config["health_endpoint"] || config[:health_endpoint]) do
      :ok
    end
  end

  @doc """
  Rejects URLs that are missing a host or target a private/metadata address.
  """
  @spec validate_public_url(term()) :: :ok | {:error, String.t()}
  def validate_public_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      not public_http_host?(uri) ->
        {:error, @blocked_url_message}

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        {:error, @blocked_url_message}

      blocked_host?(uri.host) ->
        {:error, @blocked_url_message}

      true ->
        :ok
    end
  end

  def validate_public_url(_url), do: {:error, @blocked_url_message}

  defp public_http_host?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp public_http_host?(_uri), do: false

  defp blocked_host?(host) do
    host =
      host
      |> String.trim()
      |> String.downcase()
      |> String.trim_leading("[")
      |> String.trim_trailing("]")

    host in ["localhost" | @metadata_hosts] or blocked_ip_host?(host)
  end

  defp blocked_ip_host?(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> blocked_ip?(address)
      {:error, _} -> false
    end
  end

  defp blocked_ip?({a, b, c, d})
       when a in 0..255 and b in 0..255 and c in 0..255 and d in 0..255 do
    a == 127 or a == 10 or (a == 169 and b == 254) or (a == 192 and b == 168) or
      (a == 172 and b >= 16 and b <= 31)
  end

  defp blocked_ip?({0, 0, 0, 0, 0, 65535, hi, lo}) do
    blocked_ip?({hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF})
  end

  defp blocked_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp blocked_ip?({hextet, _, _, _, _, _, _, _}) when hextet >= 0xFE80 and hextet <= 0xFEBF,
    do: true

  defp blocked_ip?({0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x0254}), do: true

  defp blocked_ip?(_address), do: false

  defp validate_url(nil), do: {:error, "url is required"}
  defp validate_url(""), do: {:error, "url cannot be empty"}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> validate_public_url(url)
      _ -> {:error, "url must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_url(_), do: {:error, "url must be a string"}

  defp validate_method(nil), do: :ok
  defp validate_method(""), do: :ok

  defp validate_method(method) when is_binary(method) do
    normalized = String.downcase(method)

    if normalized in ["get", "post", "put", "patch", "delete"] do
      :ok
    else
      {:error, "method must be one of: get, post, put, patch, delete"}
    end
  end

  defp validate_method(_), do: {:error, "method must be a string"}

  defp validate_headers(nil), do: :ok

  defp validate_headers(headers) when is_map(headers) do
    Enum.all?(headers, fn {k, v} ->
      is_binary(k) and is_binary(v)
    end)
    |> case do
      true -> :ok
      false -> {:error, "headers must be a map with string keys and values"}
    end
  end

  defp validate_headers(_), do: {:error, "headers must be a map"}

  defp validate_timeout(config),
    do: RuntimeTimeout.validate(config, max_ms: @max_timeout, field: "timeout")

  defp validate_auth_token(nil), do: :ok

  defp validate_auth_token(token) when is_binary(token) do
    if String.trim(token) != "" do
      :ok
    else
      {:error, "auth_token cannot be empty"}
    end
  end

  defp validate_auth_token(_), do: {:error, "auth_token must be a string"}

  defp validate_callback_url(nil), do: :ok

  defp validate_callback_url(url) when is_binary(url) do
    if String.trim(url) != "" do
      case URI.parse(url) do
        %URI{scheme: scheme} when scheme in ["http", "https"] ->
          case validate_public_url(url) do
            :ok -> :ok
            {:error, _} = error -> error
          end

        _ ->
          {:error, "callback_url must be a valid HTTP/HTTPS URL"}
      end
    else
      {:error, "callback_url cannot be empty"}
    end
  end

  defp validate_callback_url(_), do: {:error, "callback_url must be a string"}

  defp validate_health_endpoint(nil), do: :ok
  defp validate_health_endpoint(""), do: :ok

  defp validate_health_endpoint(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> validate_public_url(url)
      _ -> {:error, "url must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_health_endpoint(_), do: {:error, "url must be a string"}
end
