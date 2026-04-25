defmodule Cympho.Adapters.OpenClawAdapter do
  @moduledoc """
  OpenClaw protocol adapter.

  Runs agents via the OpenClaw HTTP protocol for agent integration.
  OpenClaw provides a standardized interface for agent execution and communication.
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

    case dispatch_to_openclaw(issue, agent_id, config) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp dispatch_to_openclaw(issue, agent_id, config) do
    endpoint = get_endpoint(config)
    api_key = get_api_key(config)

    cond do
      is_nil(endpoint) or endpoint == "" ->
        {:error, :no_endpoint_configured}

      true ->
        payload = build_openclaw_payload(issue, agent_id, config)
        make_openclaw_request(endpoint, api_key, payload)
    end
  end

  defp build_openclaw_payload(issue, agent_id, config) do
    base = %{
      "version" => "1.0",
      "agent_id" => agent_id,
      "task" => %{
        "id" => issue.id,
        "title" => issue.title,
        "description" => issue.description || "",
        "metadata" => %{
          "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "type" => "paperclip_issue"
        }
      }
    }

    # Merge with custom config if provided
    custom_context = config[:context] || config["context"]

    if custom_context do
      put_in(base, ["task", "context"], custom_context)
    else
      base
    end
  end

  defp make_openclaw_request(endpoint, api_key, payload) do
    url = build_openclaw_url(endpoint)

    headers = [
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    headers =
      if api_key do
        [{"authorization", "Bearer #{api_key}"} | headers]
      else
        headers
      end

    body = Jason.encode!(payload)

    case :httpc.request(
      :post,
      {url, headers, "application/json", body},
      [],
      body_format: :binary
    ) do
      {:ok, {{_, status_code, _}, _headers, response_body}} when status_code in 200..299 ->
        parse_openclaw_response(response_body)

      {:ok, {{_, status_code, _}, _headers, response_body}} ->
        {:error, {:http_error, status_code, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp build_openclaw_url(endpoint) do
    base = String.trim_trailing(endpoint, "/")
    "#{base}/openclaw/v1/tasks"
  end

  defp parse_openclaw_response(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => data}} when is_map(data) ->
        {:ok, data}

      {:ok, %{"result" => result}} when is_map(result) ->
        {:ok, result}

      {:ok, other} ->
        {:ok, other}

      {:error, _} ->
        {:ok, %{raw_response: body}}
    end
  end

  defp get_endpoint(config) do
    config[:endpoint] || config["endpoint"] ||
      Application.get_env(:cympho, :openclaw_endpoint)
  end

  defp get_api_key(config) do
    config[:api_key] || config["api_key"] ||
      Application.get_env(:cympho, :openclaw_api_key)
  end

  @impl true
  def health_check(config) do
    endpoint = get_endpoint(config)

    cond do
      is_nil(endpoint) or endpoint == "" ->
        %{status: :unhealthy, message: "No OpenClaw endpoint configured", checked_at: DateTime.utc_now()}

      true ->
        check_openclaw_health(endpoint)
    end
  end

  defp check_openclaw_health(endpoint) do
    health_url = String.trim_trailing(endpoint, "/") <> "/openclaw/v1/health"

    case :httpc.request(:get, {health_url, []}, [], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        %{status: :healthy, message: "OpenClaw endpoint reachable", checked_at: DateTime.utc_now()}

      {:ok, {{_, status, _}, _, _}} ->
        %{status: :degraded, message: "OpenClaw endpoint returned #{status}", checked_at: DateTime.utc_now()}

      {:error, _} ->
        %{status: :unhealthy, message: "OpenClaw endpoint unreachable", checked_at: DateTime.utc_now()}
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
        description: "OpenClaw endpoint URL (e.g., https://api.openclaw.example.com)"
      },
      %{
        key: :api_key,
        type: :string,
        required: false,
        default: nil,
        description: "OpenClaw API key for authentication"
      },
      %{
        key: :context,
        type: :map,
        required: false,
        default: nil,
        description: "Additional context to include in task payload"
      }
    ]
  end

  @impl true
  def name, do: "OpenClaw"

  @impl true
  def available? do
    endpoint = Application.get_env(:cympho, :openclaw_endpoint)
    not is_nil(endpoint)
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_endpoint(config["endpoint"] || config[:endpoint]),
         :ok <- validate_api_key(config["api_key"] || config[:api_key]),
         :ok <- validate_context(config["context"] || config[:context]) do
      :ok
    end
  end

  defp validate_endpoint(nil), do: {:error, "endpoint is required"}
  defp validate_endpoint(""), do: {:error, "endpoint cannot be empty"}

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> :ok
      _ -> {:error, "endpoint must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_endpoint(_), do: {:error, "endpoint must be a string"}

  defp validate_api_key(nil), do: :ok
  defp validate_api_key(key) when is_binary(key), do: :ok
  defp validate_api_key(_), do: {:error, "api_key must be a string"}

  defp validate_context(nil), do: :ok

  defp validate_context(context) when is_map(context) do
    if Enum.all?(context, fn {k, v} -> is_binary(k) end) do
      :ok
    else
      {:error, "context must be a map with string keys"}
    end
  end

  defp validate_context(_), do: {:error, "context must be a map"}
end
