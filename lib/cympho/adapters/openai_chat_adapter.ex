defmodule Cympho.Adapters.OpenAIChatAdapter do
  @moduledoc """
  OpenAI-compatible Chat Completions adapter.

  This adapter is for hosted providers that expose the OpenAI
  `/chat/completions` shape, such as DashScope compatible mode. It sends the
  standard Cympho agent prompt and returns the normal orchestrator text content
  payload.
  """

  @behaviour Cympho.Adapters.Adapter

  @default_timeout 120_000
  @default_model "qwen3.7-plus"
  @max_response_bytes 2 * 1024 * 1024
  @default_system_prompt """
  You are a Cympho runtime agent. Work only from the supplied issue context and \
  the allowed Cympho action contract. Keep owner-visible progress concise, do \
  not expose secrets, and do not include private reasoning.

  Before claiming completion, report verification evidence. When your turn \
  changes state, hands work off, or asks the owner to decide, include:
  - Evidence produced: artifact, PR, test, log, decision, or issue memory created.
  - Evidence inspected: what you checked before making the claim.
  - Restart packet: current state, next command or action, and blockers.

  Emit cympho-actions JSON only when requesting Cympho side effects.
  """

  @impl true
  def run(issue, agent_id, recipient_pid, opts) when is_pid(recipient_pid) do
    session_id = make_ref()
    config = opts[:config] || %{}

    spawn(fn ->
      do_run(session_id, issue, agent_id, recipient_pid, config, opts)
    end)

    session_id
  end

  defp do_run(session_id, issue, agent_id, recipient_pid, config, opts) do
    send(recipient_pid, {:session_started, session_id})

    prompt =
      Cympho.AgentPrompt.build(issue, agent_id,
        skills: Keyword.get(opts, :skills, []),
        runtime_context: Keyword.get(opts, :runtime_context),
        wake_context: Keyword.get(opts, :wake_context)
      )

    case call_chat_completion(prompt, config) do
      {:ok, result} -> send(recipient_pid, {:turn_completed, session_id, result})
      {:error, reason} -> send(recipient_pid, {:turn_ended_with_error, session_id, reason})
    end
  end

  defp call_chat_completion(prompt, config) do
    with :ok <- validate_config(config),
         {:ok, payload} <- build_payload(prompt, config),
         {:ok, response} <-
           request(normalize_chat_url(endpoint(config)), api_key(config), payload, config),
         {:ok, result} <- parse_chat_response(response.body) do
      {:ok, result}
    end
  end

  defp build_payload(prompt, config) do
    payload =
      %{
        "model" => model(config),
        "messages" => [
          %{
            "role" => "system",
            "content" => config_value(config, "system_prompt") || @default_system_prompt
          },
          %{"role" => "user", "content" => prompt}
        ],
        "temperature" => numeric_config(config, "temperature", 0.2)
      }
      |> maybe_put("max_tokens", integer_config(config, "max_tokens"))

    {:ok, payload}
  end

  defp request(url, api_key, payload, config) do
    timeout = integer_config(config, "timeout") || @default_timeout

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    Finch.build(:post, url, headers, Jason.encode!(payload))
    |> stream_to_acc(timeout)
  end

  defp stream_to_acc(req, timeout) do
    init = %{status: nil, body: [], size: 0, overflow: false}

    fun = fn
      {:status, status}, acc ->
        %{acc | status: status}

      {:headers, _headers}, acc ->
        acc

      {:data, _chunk}, %{overflow: true} = acc ->
        acc

      {:data, chunk}, acc ->
        size = acc.size + byte_size(chunk)

        if size > @max_response_bytes do
          %{acc | overflow: true}
        else
          %{acc | body: [chunk | acc.body], size: size}
        end
    end

    case Finch.stream(req, Cympho.Finch, init, fun, receive_timeout: timeout) do
      {:ok, %{overflow: true}} ->
        {:error, :response_too_large}

      {:ok, %{status: status, body: chunks}} when status in 200..299 ->
        {:ok, %{status: status, body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

      {:ok, %{status: status, body: chunks}} ->
        body = chunks |> Enum.reverse() |> IO.iodata_to_binary()
        {:error, {:http_error, status, error_message(body)}}

      {:error, %Finch.Error{} = error, _acc} ->
        {:error, {:finch_error, Exception.message(error)}}

      {:error, reason, _acc} ->
        {:error, {:request_error, stream_error_message(reason)}}

      {:error, %Finch.Error{} = error} ->
        {:error, {:finch_error, Exception.message(error)}}

      {:error, reason} ->
        {:error, {:request_error, stream_error_message(reason)}}
    end
  end

  defp stream_error_message(%{__struct__: _} = error) do
    Exception.message(error)
  rescue
    _ -> inspect(error)
  end

  defp stream_error_message(reason), do: reason

  @doc false
  def parse_chat_response(body) when is_binary(body) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, content} <- extract_content(decoded) do
      {:ok, %{"content" => [%{"type" => "text", "text" => String.trim(content)}]}}
    else
      {:error, %Jason.DecodeError{} = error} -> {:error, {:parse_error, Exception.message(error)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    normalize_content(content)
  end

  defp extract_content(%{"choices" => [%{"delta" => %{"content" => content}} | _]}) do
    normalize_content(content)
  end

  defp extract_content(_), do: {:error, {:parse_error, "missing choices[0].message.content"}}

  defp normalize_content(content) when is_binary(content) do
    if String.trim(content) == "" do
      {:error, :no_output}
    else
      {:ok, content}
    end
  end

  defp normalize_content(content) when is_list(content) do
    text =
      content
      |> Enum.map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> text
        %{"text" => text} when is_binary(text) -> text
        text when is_binary(text) -> text
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    normalize_content(text)
  end

  defp normalize_content(_), do: {:error, {:parse_error, "message content is not text"}}

  defp error_message(body) do
    case Jason.decode(body) do
      {:ok, %{"error" => %{"message" => message}}} when is_binary(message) -> message
      {:ok, %{"message" => message}} when is_binary(message) -> message
      {:ok, decoded} -> inspect(decoded)
      {:error, _} -> String.slice(body, 0, 2_000)
    end
  end

  @impl true
  def health_check(config) do
    cond do
      blank?(endpoint(config)) ->
        %{
          status: :unhealthy,
          message: "No chat completions endpoint configured",
          checked_at: DateTime.utc_now()
        }

      blank?(api_key(config)) ->
        %{status: :degraded, message: "No API key configured", checked_at: DateTime.utc_now()}

      blank?(model(config)) ->
        %{status: :degraded, message: "No model configured", checked_at: DateTime.utc_now()}

      true ->
        %{
          status: :healthy,
          message: "OpenAI-compatible chat configuration is present",
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
        description: "OpenAI-compatible chat completions endpoint"
      },
      %{
        key: :api_key,
        type: :string,
        required: true,
        default: nil,
        description: "Bearer token for the compatible provider"
      },
      %{
        key: :model,
        type: :string,
        required: true,
        default: @default_model,
        description: "Provider model id"
      },
      %{
        key: :timeout,
        type: :integer,
        required: false,
        default: @default_timeout,
        description: "Request timeout in milliseconds"
      },
      %{
        key: :max_tokens,
        type: :integer,
        required: false,
        default: nil,
        description: "Optional provider max_tokens value"
      },
      %{
        key: :temperature,
        type: :float,
        required: false,
        default: 0.2,
        description: "Sampling temperature"
      }
    ]
  end

  @impl true
  def name, do: "OpenAI Chat"

  @impl true
  def type, do: :openai_chat

  @impl true
  def available?, do: true

  @impl true
  def available?(_config), do: true

  @impl true
  def validate_config(config) do
    with :ok <- validate_endpoint(endpoint(config)),
         :ok <- validate_api_key(api_key(config)),
         :ok <- validate_model(model(config)),
         :ok <- validate_optional_integer(config, "timeout"),
         :ok <- validate_optional_integer(config, "max_tokens"),
         :ok <- validate_optional_number(config, "temperature") do
      :ok
    end
  end

  defp endpoint(config), do: config_value(config, "endpoint") || config_value(config, "base_url")
  defp api_key(config), do: config_value(config, "api_key")
  defp model(config), do: config_value(config, "model") || @default_model

  @doc false
  def normalize_chat_url(endpoint) when endpoint in [nil, ""], do: ""

  def normalize_chat_url(endpoint) do
    endpoint = endpoint |> to_string() |> String.trim()

    if endpoint == "" do
      ""
    else
      uri = URI.parse(endpoint)
      path = uri.path || ""
      path = String.trim_trailing(path, "/")

      path =
        if String.ends_with?(path, "/chat/completions") do
          path
        else
          path <> "/chat/completions"
        end

      URI.to_string(%{uri | path: path})
    end
  end

  defp config_value(config, key) when is_map(config) do
    Map.get(config, key) || atom_key(config, key)
  end

  defp config_value(_config, _key), do: nil

  defp atom_key(map, key) do
    Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> nil
  end

  defp integer_config(config, key) do
    case config_value(config, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value)
      _ -> nil
    end
  end

  defp numeric_config(config, key, default) do
    case config_value(config, key) do
      value when is_integer(value) -> value
      value when is_float(value) -> value
      value when is_binary(value) -> parse_float(value) || default
      _ -> default
    end
  end

  defp parse_integer(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_float(value) do
    case Float.parse(String.trim(value)) do
      {float, ""} -> float
      _ -> nil
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp validate_endpoint(value) when is_binary(value) do
    value = String.trim(value)

    with false <- value == "",
         %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) <-
           URI.parse(value) do
      :ok
    else
      true -> {:error, "endpoint cannot be empty"}
      _ -> {:error, "endpoint must be a valid HTTP/HTTPS URL"}
    end
  end

  defp validate_endpoint(nil), do: {:error, "endpoint is required"}
  defp validate_endpoint(_), do: {:error, "endpoint must be a string"}

  defp validate_api_key(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "api_key cannot be empty"}, else: :ok
  end

  defp validate_api_key(nil), do: {:error, "api_key is required"}
  defp validate_api_key(_), do: {:error, "api_key must be a string"}

  defp validate_model(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, "model cannot be empty"}, else: :ok
  end

  defp validate_model(nil), do: {:error, "model is required"}
  defp validate_model(_), do: {:error, "model must be a string"}

  defp validate_optional_integer(config, key) do
    case config_value(config, key) do
      value when value in [nil, ""] ->
        :ok

      value when is_integer(value) and value > 0 ->
        :ok

      value when is_binary(value) ->
        case parse_integer(value) do
          integer when is_integer(integer) and integer > 0 -> :ok
          _ -> {:error, "#{key} must be a positive integer"}
        end

      _ ->
        {:error, "#{key} must be a positive integer"}
    end
  end

  defp validate_optional_number(config, key) do
    case config_value(config, key) do
      value when value in [nil, ""] ->
        :ok

      value when is_integer(value) or is_float(value) ->
        :ok

      value when is_binary(value) ->
        if parse_float(value), do: :ok, else: {:error, "#{key} must be a number"}

      _ ->
        {:error, "#{key} must be a number"}
    end
  end

  defp blank?(value), do: value in [nil, ""]
end
