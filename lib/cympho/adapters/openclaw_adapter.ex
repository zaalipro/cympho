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

    base
    |> maybe_put("provider", config[:provider] || config["provider"])
    |> maybe_put("model", config[:model] || config["model"])
    |> maybe_put_runtime(config)
    |> maybe_put_context(config[:context] || config["context"])
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_runtime(payload, config) do
    runtime = config[:agent_runtime] || config["agent_runtime"]
    harness_id = config[:harness_id] || config["harness_id"]

    cond do
      runtime in [nil, ""] and harness_id in [nil, ""] ->
        payload

      true ->
        runtime_payload =
          %{}
          |> maybe_put("type", runtime)
          |> maybe_put("agentId", harness_id)

        Map.put(payload, "runtime", runtime_payload)
    end
  end

  defp maybe_put_context(payload, nil), do: payload
  defp maybe_put_context(payload, context), do: put_in(payload, ["task", "context"], context)

  defp make_openclaw_request(endpoint, api_key, payload) do
    # Ensure inets application is started before using :httpc
    case Application.ensure_all_started(:inets) do
      {:ok, _} ->
        do_make_openclaw_request(endpoint, api_key, payload)

      {:error, reason} ->
        {:error, {:inets_start_failed, reason}}
    end
  end

  defp do_make_openclaw_request(endpoint, api_key, payload) do
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
        %{
          status: :unhealthy,
          message: "No OpenClaw endpoint configured",
          checked_at: DateTime.utc_now()
        }

      true ->
        check_openclaw_health(endpoint)
    end
  end

  defp check_openclaw_health(endpoint) do
    health_url = String.trim_trailing(endpoint, "/") <> "/openclaw/v1/health"

    # Ensure inets is started before using :httpc
    case Application.ensure_all_started(:inets) do
      {:ok, _} ->
        do_health_check_request(health_url)

      {:error, _reason} ->
        %{
          status: :unhealthy,
          message: "Failed to start inets application",
          checked_at: DateTime.utc_now()
        }
    end
  end

  defp do_health_check_request(health_url) do
    case :httpc.request(:get, {health_url, []}, [], []) do
      {:ok, {{_, 200, _}, _, _}} ->
        %{
          status: :healthy,
          message: "OpenClaw endpoint reachable",
          checked_at: DateTime.utc_now()
        }

      {:ok, {{_, status, _}, _, _}} ->
        %{
          status: :degraded,
          message: "OpenClaw endpoint returned #{status}",
          checked_at: DateTime.utc_now()
        }

      {:error, _} ->
        %{
          status: :unhealthy,
          message: "OpenClaw endpoint unreachable",
          checked_at: DateTime.utc_now()
        }
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
        key: :provider,
        type: :string,
        required: false,
        default: Cympho.Adapters.RuntimeOptions.openclaw_default_provider(),
        options: Cympho.Adapters.RuntimeOptions.openclaw_provider_options(),
        description: "OpenClaw model provider id"
      },
      %{
        key: :model,
        type: :string,
        required: false,
        default: Cympho.Adapters.RuntimeOptions.openclaw_default_model(),
        options:
          Cympho.Adapters.RuntimeOptions.openclaw_model_options(
            Cympho.Adapters.RuntimeOptions.openclaw_default_provider()
          ),
        description: "OpenClaw model id in provider/model form"
      },
      %{
        key: :agent_runtime,
        type: :string,
        required: false,
        default: "subagent",
        options: [{"Subagent", "subagent"}, {"ACP", "acp"}],
        description: "OpenClaw runtime to request for this task"
      },
      %{
        key: :harness_id,
        type: :string,
        required: false,
        default: nil,
        description: "ACP harness id, for example codex or cursor"
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
  def type, do: :openclaw

  @impl true
  def available? do
    endpoint = Application.get_env(:cympho, :openclaw_endpoint)
    not is_nil(endpoint)
  end

  @impl true
  def validate_config(config) do
    with :ok <- validate_endpoint(config["endpoint"] || config[:endpoint]),
         :ok <- validate_api_key(config["api_key"] || config[:api_key]),
         :ok <- validate_string(config["provider"] || config[:provider], "provider"),
         :ok <- validate_string(config["model"] || config[:model], "model"),
         :ok <- validate_runtime(config["agent_runtime"] || config[:agent_runtime]),
         :ok <- validate_string(config["harness_id"] || config[:harness_id], "harness_id"),
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

  defp validate_string(nil, _field), do: :ok
  defp validate_string("", _field), do: :ok
  defp validate_string(value, _field) when is_binary(value), do: :ok
  defp validate_string(_value, field), do: {:error, "#{field} must be a string"}

  defp validate_runtime(nil), do: :ok
  defp validate_runtime(""), do: :ok
  defp validate_runtime(runtime) when runtime in ["subagent", "acp"], do: :ok
  defp validate_runtime(_), do: {:error, "agent_runtime must be subagent or acp"}

  defp validate_context(nil), do: :ok

  defp validate_context(context) when is_map(context) do
    if Enum.all?(context, fn {k, _v} -> is_binary(k) end) do
      :ok
    else
      {:error, "context must be a map with string keys"}
    end
  end

  defp validate_context(_), do: {:error, "context must be a map"}
end
