defmodule Cympho.Agrenting.Client do
  @moduledoc """
  Thin HTTP client for the Agrenting marketplace API.
  """

  @default_base_url "https://www.agrenting.com"
  @default_timeout 30_000
  @mcp_protocol_version "2024-11-05"

  def default_base_url, do: @default_base_url

  def list_agents(config, params \\ %{}) do
    query =
      params
      |> Map.put_new("status", "active")
      |> compact_query()

    request(config, :get, "/api/v1/agents", nil, query: query)
  end

  def get_agent(config, did) when is_binary(did) do
    request(config, :get, "/api/v1/agents/#{URI.encode(did)}")
  end

  def create_hiring(config, agent_did, attrs) when is_binary(agent_did) and is_map(attrs) do
    request(config, :post, "/api/v1/agents/#{URI.encode(agent_did)}/hire", attrs)
  end

  def get_hiring(config, hiring_id) when is_binary(hiring_id) do
    case request(config, :get, "/api/v1/hirings/#{URI.encode(hiring_id)}") do
      {:error, {:http_error, 404, _message}} ->
        get_hiring_via_mcp(config, hiring_id)

      result ->
        result
    end
  end

  def cancel_hiring(config, hiring_id) when is_binary(hiring_id) do
    request(config, :post, "/api/v1/hirings/#{URI.encode(hiring_id)}/cancel", %{})
  end

  def health(config) do
    request(config, :get, "/api/v1/health", nil, auth?: false)
  end

  def request(config, method, path, body \\ nil, opts \\ []) do
    with {:ok, url} <- build_url(config, path, Keyword.get(opts, :query, %{})),
         {:ok, headers} <- headers(config, Keyword.get(opts, :auth?, true)),
         {:ok, encoded} <- encode_body(body) do
      req = Finch.build(method, url, headers, encoded)
      timeout = config_value(config, "timeout") || @default_timeout

      case Finch.request(req, Cympho.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status, body: response_body}} when status in 200..299 ->
          decode_success(response_body)

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:error, {:http_error, status, error_message(response_body)}}

        {:error, %Finch.Error{} = error} ->
          {:error, {:finch_error, Exception.message(error)}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  def config_value(config, key) when is_map(config) and is_binary(key) do
    Map.get(config, key) || Map.get(config, String.to_atom(key))
  rescue
    ArgumentError -> Map.get(config, key)
  end

  def config_value(_config, _key), do: nil

  defp build_url(config, path, query) do
    base =
      config_value(config, "base_url") ||
        config_value(config, "agrenting_url") ||
        config_value(config, "url") ||
        Application.get_env(:cympho, :agrenting_url) ||
        @default_base_url

    uri = URI.parse(String.trim_trailing(to_string(base), "/") <> path)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) do
      query_string = URI.encode_query(query || %{})
      uri = if query_string == "", do: uri, else: %{uri | query: query_string}
      {:ok, URI.to_string(uri)}
    else
      {:error, :invalid_base_url}
    end
  end

  defp headers(_config, false), do: {:ok, [{"accept", "application/json"}]}

  defp headers(config, true) do
    case config_value(config, "api_key") do
      key when is_binary(key) and key != "" ->
        {:ok,
         [
           {"accept", "application/json"},
           {"content-type", "application/json"},
           {"authorization", "Bearer #{key}"}
         ]}

      _ ->
        {:error, :missing_api_key}
    end
  end

  defp encode_body(nil), do: {:ok, nil}

  defp encode_body(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, {:json_encode_error, reason}}
    end
  end

  defp decode_success(""), do: {:ok, %{}}

  defp decode_success(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => data}} -> {:ok, data}
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:ok, body}
    end
  end

  defp error_message(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"errors" => [%{"message" => message} | _]}} -> message
      {:ok, %{"error" => %{"message" => message}}} -> message
      {:ok, decoded} -> inspect(decoded)
      {:error, _} -> String.slice(body, 0, 500)
    end
  end

  defp compact_query(params) do
    params
    |> Enum.reject(fn {_key, value} -> value in [nil, ""] end)
    |> Map.new(fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp get_hiring_via_mcp(config, hiring_id) do
    with {:ok, status} <-
           call_hirer_mcp_tool(config, "get_hiring_status", %{"hiring_id" => hiring_id}) do
      {:ok, normalize_mcp_hiring(status, hiring_id)}
    end
  end

  defp call_hirer_mcp_tool(config, name, arguments) do
    timeout = config_value(config, "timeout") || @default_timeout
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        stream_mcp_events(config, parent, ref, timeout)
      end)

    try do
      with {:ok, endpoint} <- receive_mcp_endpoint(ref, timeout),
           :ok <- post_mcp_message(config, endpoint, initialize_message(1), timeout),
           {:ok, _} <- receive_mcp_response(ref, 1, timeout),
           :ok <- post_mcp_message(config, endpoint, initialized_message(), timeout),
           :ok <-
             post_mcp_message(config, endpoint, tool_call_message(2, name, arguments), timeout),
           {:ok, response} <- receive_mcp_response(ref, 2, timeout) do
        decode_tool_response(response)
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp stream_mcp_events(config, parent, ref, timeout) do
    with {:ok, url} <- build_url(config, "/mcp/hirer/sse", %{}),
         {:ok, headers} <- headers(config, true) do
      headers = [{"accept", "text/event-stream"} | reject_header(headers, "accept")]
      req = Finch.build(:get, url, headers)
      init = %{buffer: ""}

      fun = fn
        {:data, chunk}, acc ->
          consume_sse_chunk(acc, chunk, parent, ref)

        _event, acc ->
          acc
      end

      Finch.stream(req, Cympho.Finch, init, fun, receive_timeout: timeout)
    end
  end

  defp consume_sse_chunk(acc, chunk, parent, ref) do
    buffer = String.replace(acc.buffer <> chunk, "\r\n", "\n")
    parts = String.split(buffer, "\n\n")
    {frames, [rest]} = Enum.split(parts, -1)

    Enum.each(frames, fn frame ->
      case parse_sse_frame(frame) do
        {"endpoint", endpoint} when endpoint != "" ->
          send(parent, {:agrenting_mcp_endpoint, ref, endpoint})

        {_event, data} when data != "" ->
          case Jason.decode(data) do
            {:ok, %{"id" => id} = response} ->
              send(parent, {:agrenting_mcp_response, ref, id, response})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)

    %{acc | buffer: rest}
  end

  defp parse_sse_frame(frame) do
    lines = String.split(frame, "\n")

    event =
      Enum.find_value(lines, "message", fn
        "event:" <> value -> String.trim(value)
        _ -> nil
      end)

    data =
      lines
      |> Enum.flat_map(fn
        "data:" <> value -> [String.trim_leading(value)]
        _ -> []
      end)
      |> Enum.join("\n")

    {event, data}
  end

  defp receive_mcp_endpoint(ref, timeout) do
    receive do
      {:agrenting_mcp_endpoint, ^ref, endpoint} -> {:ok, endpoint}
    after
      timeout -> {:error, :agrenting_mcp_endpoint_timeout}
    end
  end

  defp receive_mcp_response(ref, id, timeout) do
    receive do
      {:agrenting_mcp_response, ^ref, ^id, response} -> {:ok, response}
    after
      timeout -> {:error, {:agrenting_mcp_response_timeout, id}}
    end
  end

  defp post_mcp_message(config, endpoint, message, timeout) do
    with {:ok, url} <- mcp_message_url(config, endpoint),
         {:ok, headers} <- headers(config, true),
         {:ok, body} <- encode_body(message) do
      headers = [{"content-type", "application/json"} | reject_header(headers, "content-type")]
      req = Finch.build(:post, url, headers, body)

      case Finch.request(req, Cympho.Finch, receive_timeout: timeout) do
        {:ok, %Finch.Response{status: status}} when status in 200..299 ->
          :ok

        {:ok, %Finch.Response{status: status, body: response_body}} ->
          {:error, {:mcp_http_error, status, error_message(response_body)}}

        {:error, %Finch.Error{} = error} ->
          {:error, {:finch_error, Exception.message(error)}}

        {:error, reason} ->
          {:error, {:request_error, reason}}
      end
    end
  end

  defp initialize_message(id) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => @mcp_protocol_version,
        "capabilities" => %{},
        "clientInfo" => %{"name" => "cympho", "version" => "0.1.0"}
      }
    }
  end

  defp initialized_message do
    %{"jsonrpc" => "2.0", "method" => "notifications/initialized", "params" => %{}}
  end

  defp tool_call_message(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp decode_tool_response(%{"error" => %{"message" => message}}),
    do: {:error, {:mcp_error, message}}

  defp decode_tool_response(%{"result" => %{"isError" => true} = result}) do
    {:error, {:mcp_tool_error, tool_text(result)}}
  end

  defp decode_tool_response(%{"result" => result}) do
    case Jason.decode(tool_text(result)) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_mcp_tool_response}
    end
  end

  defp decode_tool_response(_), do: {:error, :invalid_mcp_response}

  defp tool_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.find_value("", fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp tool_text(_), do: ""

  defp normalize_mcp_hiring(status, hiring_id) do
    id = status["id"] || status["hiring_id"] || hiring_id

    status
    |> Map.put("id", id)
    |> Map.put_new("task_output", %{})
    |> Map.put_new("artifacts", mcp_artifacts(status["artifact_ids"]))
    |> maybe_put_mcp_agent()
  end

  defp maybe_put_mcp_agent(%{"agent" => _agent} = hiring), do: hiring

  defp maybe_put_mcp_agent(hiring) do
    agent =
      %{}
      |> put_if_present("did", hiring["agent_did"])
      |> put_if_present("name", hiring["agent_name"])

    if map_size(agent) == 0, do: hiring, else: Map.put(hiring, "agent", agent)
  end

  defp mcp_artifacts(ids) when is_list(ids) do
    Enum.map(ids, fn
      id when is_binary(id) -> %{"id" => id}
      artifact when is_map(artifact) -> artifact
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp mcp_artifacts(_), do: []

  defp mcp_message_url(config, endpoint) when is_binary(endpoint) do
    if String.starts_with?(endpoint, ["http://", "https://"]) do
      {:ok, endpoint}
    else
      build_url(config, endpoint, %{})
    end
  end

  defp reject_header(headers, key) do
    Enum.reject(headers, fn {name, _value} -> String.downcase(name) == key end)
  end

  defp put_if_present(map, _key, value) when value in [nil, ""], do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)
end
