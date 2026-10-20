defmodule Cympho.Agrenting.ClientTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Agrenting.Client

  test "passes receive and request deadlines to Finch independently" do
    test_pid = self()

    stream = fn _request, _name, initial, callback, opts ->
      send(test_pid, {:finch_options, opts})
      {:cont, acc} = callback.({:status, 200}, initial)
      {:cont, acc} = callback.({:data, "{}"}, acc)
      {:ok, acc}
    end

    with_mocks [
      {Finch, [:passthrough],
       [
         stream_while: stream
       ]}
    ] do
      assert {:ok, %{}} =
               Client.request(
                 %{"api_key" => "test", "timeout" => 100, "request_timeout" => 250},
                 :get,
                 "/health"
               )

      assert_receive {:finch_options, opts}
      assert opts[:receive_timeout] == 100
      assert opts[:request_timeout] == 250
    end
  end

  test "rejects a successful response body above the configured limit" do
    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 200}, initial)

      case callback.({:data, String.duplicate("x", 33)}, acc) do
        {:halt, overflow_acc} -> {:ok, overflow_acc}
        {:cont, next_acc} -> {:ok, next_acc}
      end
    end

    with_mocks [
      {Finch, [:passthrough],
       [
         stream_while: stream
       ]}
    ] do
      assert {:error, {:agrenting_response_too_large, 32}} =
               Client.request(
                 %{"api_key" => "test", "max_response_bytes" => 32},
                 :get,
                 "/health"
               )
    end
  end

  test "halts a response stream at the body limit instead of consuming later chunks" do
    test_pid = self()

    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 200}, initial)
      {:cont, acc} = callback.({:data, String.duplicate("x", 32)}, acc)
      result = callback.({:data, "overflow"}, acc)
      send(test_pid, {:overflow_result, result})
      {:halt, overflow_acc} = result
      {:ok, overflow_acc}
    end

    with_mocks [
      {Finch, [:passthrough], [stream_while: stream]}
    ] do
      assert {:error, {:agrenting_response_too_large, 32}} =
               Client.request(
                 %{"api_key" => "test", "max_response_bytes" => 32},
                 :get,
                 "/health"
               )

      assert_receive {:overflow_result, {:halt, {:overflow, 32}}}
    end
  end

  test "redacts the API key before cutting a non-JSON error body" do
    api_key = "agrenting-sentinel-key-" <> String.duplicate("K", 20)
    body = String.duplicate("x", 490) <> " " <> api_key <> " rejected"

    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 401}, initial)
      {:cont, acc} = callback.({:data, body}, acc)
      {:ok, acc}
    end

    with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
      assert {:error, {:http_error, 401, message}} =
               Client.request(%{"api_key" => api_key}, :get, "/api/v1/agents")

      refute message =~ "agrent"
      assert message =~ "[REDACTE"
    end
  end

  test "redacts the API key before inspect/1 truncates a JSON error body" do
    api_key = "agrenting-sentinel-key-" <> String.duplicate("K", 20)
    # inspect/1 keeps 4_096 bytes of a string, which ends inside the key.
    body = Jason.encode!(%{"detail" => String.duplicate("x", 4_060) <> " " <> api_key})

    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 401}, initial)
      {:cont, acc} = callback.({:data, body}, acc)
      {:ok, acc}
    end

    with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
      assert {:error, {:http_error, 401, message}} =
               Client.request(%{"api_key" => api_key}, :get, "/api/v1/agents")

      refute message =~ "agrenting-sen"
      assert message =~ "[REDACTED]"
    end
  end

  test "redacts the API key from a JSON error body's keys" do
    api_key = "agrenting-sentinel-key-0123"
    body = Jason.encode!(%{api_key => "unknown key"})

    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 401}, initial)
      {:cont, acc} = callback.({:data, body}, acc)
      {:ok, acc}
    end

    with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
      assert {:error, {:http_error, 401, message}} =
               Client.request(%{"api_key" => api_key}, :get, "/api/v1/agents")

      assert message =~ ~s("[REDACTED]" => "unknown key")
      refute message =~ "agrenting-sentinel"
    end
  end

  test "redacts the API key from both recognised JSON error message shapes" do
    api_key = "agrenting-sentinel-key-0123"

    for body <- [
          Jason.encode!(%{"errors" => [%{"message" => "invalid key #{api_key}"}]}),
          Jason.encode!(%{"error" => %{"message" => "invalid key #{api_key}"}})
        ] do
      stream = fn _request, _name, initial, callback, _opts ->
        {:cont, acc} = callback.({:status, 401}, initial)
        {:cont, acc} = callback.({:data, body}, acc)
        {:ok, acc}
      end

      with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
        assert {:error, {:http_error, 401, "invalid key [REDACTED]"}} =
                 Client.list_agents(%{"api_key" => api_key})
      end
    end
  end

  test "redacts the API key from an MCP stream transport error" do
    api_key = "agrenting-sentinel-key-0123"

    stream = fn request, _name, initial, callback, _opts ->
      case {request.method, request.path} do
        {"GET", "/api/v1/hirings/hiring-1"} ->
          {:cont, acc} = callback.({:status, 404}, initial)
          {:ok, acc}

        {"GET", "/mcp/hirer/sse"} ->
          reason = {:invalid_header_value, "authorization", "Bearer #{api_key}"}
          {:error, %Mint.HTTPError{module: Mint.HTTP1, reason: reason}, initial}
      end
    end

    with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
      assert {:error, reason} =
               Client.get_hiring(%{"api_key" => api_key, "timeout" => 100}, "hiring-1")

      assert %Mint.HTTPError{} = reason
      refute inspect(reason) =~ api_key
    end
  end

  test "caps oversized error responses before formatting the HTTP error" do
    stream = fn _request, _name, initial, callback, _opts ->
      {:cont, acc} = callback.({:status, 500}, initial)
      {:halt, overflow_acc} = callback.({:data, String.duplicate("x", 33)}, acc)
      {:ok, overflow_acc}
    end

    with_mocks [{Finch, [:passthrough], [stream_while: stream]}] do
      assert {:error, {:agrenting_response_too_large, 32}} =
               Client.request(
                 %{"api_key" => "test", "max_response_bytes" => 32},
                 :get,
                 "/health"
               )
    end
  end

  test "fails MCP exchange when an SSE response exceeds the configured body limit" do
    test_pid = self()
    limit = 32

    stream = fn request, _name, initial, callback, _opts ->
      invoke = fn event, acc ->
        case callback.(event, acc) do
          {:cont, next_acc} -> next_acc
          {:halt, next_acc} -> next_acc
          next_acc -> next_acc
        end
      end

      initial =
        case {request.method, request.path} do
          {"GET", "/api/v1/hirings/hiring-1"} ->
            invoke.({:status, 404}, initial)

          {"GET", "/mcp/hirer/sse"} ->
            initial = invoke.({:data, "event: endpoint\ndata: /mcp/message\n\n"}, initial)
            invoke.({:data, String.duplicate("x", limit + 1)}, initial)

          {"POST", "/mcp/message"} ->
            initial = invoke.({:status, 200}, initial)
            invoke.({:data, "{}"}, initial)
        end

      {:ok, initial}
    end

    with_mocks [
      {Finch, [:passthrough],
       [
         stream_while: stream
       ]}
    ] do
      assert {:error, {:agrenting_response_too_large, ^limit}} =
               Client.get_hiring(
                 %{
                   "api_key" => "test",
                   "timeout" => 100,
                   "max_response_bytes" => limit
                 },
                 "hiring-1"
               )

      refute_received {:finch_options, _}
      send(test_pid, :done)
    end
  end
end
