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
