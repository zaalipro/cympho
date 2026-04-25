defmodule Cympho.Adapters.OpenClawAdapter do
  @moduledoc """
  Adapter for OpenClaw agent integration protocol.

  OpenClaw provides a standardized HTTP-based protocol for agent communication,
  supporting session management, task dispatch, and result collection.
  """

  @behaviour Cympho.Adapters.Adapter

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()

    spawn(fn ->
      do_run(session_id, issue, agent_id, recipient_pid, opts)
    end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, opts) do
    send(recipient_pid, {:session_started, session_id})

    config = opts[:config] || %{}

    case dispatch_task(issue, agent_id, config) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp dispatch_task(issue, agent_id, config) do
    endpoint = get_endpoint(config)
    api_key = get_api_key(config)

    cond do
      is_nil(endpoint) or endpoint == "" ->
        {:error, :no_endpoint_configured}

      true ->
        payload = build_task_payload(issue, agent_id, config)
        headers = build_headers(api_key, config)
        timeout = get_timeout(config)

        case send_request(endpoint, payload, headers, timeout) do
          {:ok, response} ->
            parse_response(response)

          {:error, reason} ->
            {:error, {:openclaw_error, reason}}
        end
    end
  end

  defp build_task_payload(issue, agent_id, config) do
    base = %{
      protocol: "openclaw/v1",
      task: %{
        id: issue.id,
        title: issue.title,
        description: issue.description || "",
        agent_id: agent_id,
        assigned_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    instructions = config[:instructions] || config["instructions"]

    if instructions do
      put_in(base, [:task, :instructions], instructions)
    else
      base
    end
  end

  defp build_headers(api_key, config) do
    base = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    base =
      if api_key do
        base ++ [{"authorization", "Bearer #{api_key}"}]
      else
        base
      end

    custom_headers = config[:headers] || config["headers"] || []

    custom_list =
      Enum.map(custom_headers, fn
        {k, v} -> {to_string(k), to_string(v)}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    base ++ custom_list
  end

  defp send_request(endpoint, payload, headers, timeout) do
    body = Jason.encode!(payload)

    request = Finch.build(:post, endpoint, headers, body)

    case Finch.request(request, Cympho.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: status, body: resp_body}}
      when status >= 200 and status < 300 ->
        {:ok, resp_body}

      {:ok, %Finch.Response{status: status, body: resp_body}} ->
        {:error, {:http_status, status, resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"result" => result}} when is_map(result) ->
        {:ok, result}

      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, other} ->
        {:ok, %{output: other}}

      {:error, _} ->
        {:ok, %{output: body, raw: true}}
    end
  end

  defp get_endpoint(config) do
    config[:endpoint] || config["endpoint"]
  end

  defp get_api_key(config) do
    config[:api_key] || config["api_key"] ||
      Application.get_env(:cympho, :openclaw_api_key) ||
      System.get_env("OPENCLAW_API_KEY")
  end

  defp get_timeout(config) do
    config[:timeout] || config["timeout"] || 60_000
  end

  @impl true
  def health_check(config) do
    endpoint = get_endpoint(config)

    cond do
      is_nil(endpoint) or endpoint == "" ->
        %{status: :unhealthy, message: "OpenClaw endpoint not configured", checked_at: DateTime.utc_now()}

      true ->
        case Finch.build(:get, endpoint <> "/health", [])
             |> Finch.request(Cympho.Finch, receive_timeout: 5000) do
          {:ok, %Finch.Response{status: status}} when status >= 200 and status < 300 ->
            %{status: :healthy, message: "OpenClaw endpoint reachable", checked_at: DateTime.utc_now()}

          {:ok, %Finch.Response{status: status}} ->
            %{status: :degraded, message: "OpenClaw returned status #{status}", checked_at: DateTime.utc_now()}

          {:error, reason} ->
            %{status: :unhealthy, message: "OpenClaw unreachable: #{inspect(reason)}", checked_at: DateTime.utc_now()}
        end
    end
  end

  @impl true
  def config_schema do
    [
      %{
        key: :endpoint,
        type: :string,
        required: true,
        default: nil,
        description: "OpenClaw server endpoint URL"
      },
      %{
        key: :api_key,
        type: :string,
        required: false,
        default: nil,
        description: "API key for OpenClaw authentication (defaults to OPENCLAW_API_KEY env var)"
      },
      %{
        key: :instructions,
        type: :string,
        required: false,
        default: nil,
        description: "Task-level instructions sent with each dispatch"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: 60_000,
        description: "Request timeout in milliseconds"
      },
      %{
        key: :headers,
        type: :map,
        required: false,
        default: %{},
        description: "Custom HTTP headers to include in requests"
      }
    ]
  end

  @impl true
  def name, do: "OpenClaw"

  @impl true
  def available? do
    endpoint =
      Application.get_env(:cympho, :openclaw_endpoint) ||
        System.get_env("OPENCLAW_ENDPOINT")

    not is_nil(endpoint) and endpoint != ""
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_endpoint(config["endpoint"] || config[:endpoint]),
         :ok <- validate_timeout(config["timeout"] || config[:timeout]),
         :ok <- validate_headers(config["headers"] || config[:headers]) do
      :ok
    end
  end

  defp validate_endpoint(nil), do: {:error, "endpoint is required"}
  defp validate_endpoint(""), do: {:error, "endpoint cannot be empty"}

  defp validate_endpoint(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        :ok

      _ ->
        {:error, "endpoint must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_endpoint(_), do: {:error, "endpoint must be a string"}

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) do
    if timeout > 0 and timeout <= 600_000 do
      :ok
    else
      {:error, "timeout must be between 1 and 600000 milliseconds"}
    end
  end

  defp validate_timeout(_), do: {:error, "timeout must be an integer"}

  defp validate_headers(nil), do: :ok

  defp validate_headers(headers) when is_map(headers) do
    if Enum.all?(headers, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      :ok
    else
      {:error, "headers must be a map with string keys and values"}
    end
  end

  defp validate_headers(_), do: {:error, "headers must be a map"}
end
