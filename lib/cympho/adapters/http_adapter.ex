defmodule Cympho.Adapters.HttpAdapter do
  @moduledoc """
  Generic HTTP webhook adapter.

  Runs agents by making HTTP requests to external endpoints.
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

    case call_http_endpoint(issue, agent_id, config) do
      {:ok, result} ->
        send(recipient_pid, {:turn_completed, session_id, result})

      {:error, reason} ->
        send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp call_http_endpoint(issue, agent_id, config) do
    url = config[:url] || config["url"]
    method = config[:method] || config["method"] || :post
    headers = config[:headers] || config["headers"] || []
    timeout = config[:timeout] || config["timeout"] || 30_000

    if is_nil(url) or url == "" do
      {:error, :no_url_configured}
    else
      payload = build_payload(issue, agent_id, config)

      case make_http_request(method, url, headers, payload, timeout) do
        {:ok, response} ->
          parse_response(response)

        {:error, reason} ->
          {:error, {:http_error, reason}}
      end
    end
  end

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

  defp make_http_request(method, url, headers, payload, timeout) do
    # Placeholder implementation
    # In production, this would use HTTPoison or similar
    {:error, :not_implemented}
  end

  defp parse_response(response) do
    # Placeholder for response parsing
    {:error, :not_implemented}
  end

  @impl true
  def health_check(config) do
    url = config[:url] || config["url"]
    health_endpoint = config[:health_endpoint] || config["health_endpoint"]

    cond do
      is_nil(url) or url == "" ->
        %{status: :unhealthy, message: "No URL configured", checked_at: DateTime.utc_now()}

      health_endpoint ->
        # Would check health endpoint if configured
        %{status: :unknown, message: "Health check not implemented", checked_at: DateTime.utc_now()}

      true ->
        %{status: :healthy, message: "URL configured", checked_at: DateTime.utc_now()}
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
        key: :timeout,
        type: :integer,
        required: false,
        default: 30_000,
        description: "Request timeout in milliseconds"
      },
      %{
        key: :payload_template,
        type: :map,
        required: false,
        default: nil,
        description: "Custom payload template to merge with default"
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
         :ok <- validate_timeout(config["timeout"] || config[:timeout]) do
      :ok
    end
  end

  defp validate_url(nil), do: {:error, "url is required"}
  defp validate_url(""), do: {:error, "url cannot be empty"}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> :ok
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

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) when is_integer(timeout) do
    if timeout > 0 and timeout <= 300_000 do
      :ok
    else
      {:error, "timeout must be between 1 and 300000 milliseconds"}
    end
  end

  defp validate_timeout(_), do: {:error, "timeout must be an integer"}
end
