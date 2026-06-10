defmodule Cympho.Adapters.OpenAIChatAdapterTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Adapters.OpenAIChatAdapter

  describe "parse_chat_response/1" do
    test "returns orchestrator text content from chat completions response" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{"message" => %{"content" => " [owner_update] CEO reviewed the flow. "}}
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => text}]}} =
               OpenAIChatAdapter.parse_chat_response(body)

      assert text == "[owner_update] CEO reviewed the flow."
    end

    test "joins provider text content arrays" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => [
                  %{"type" => "text", "text" => "First"},
                  %{"type" => "text", "text" => "Second"}
                ]
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"text" => "First\nSecond"}]}} =
               OpenAIChatAdapter.parse_chat_response(body)
    end

    test "rejects responses without text content" do
      body = Jason.encode!(%{"choices" => [%{"message" => %{"content" => ""}}]})
      assert {:error, :no_output} = OpenAIChatAdapter.parse_chat_response(body)
    end
  end

  describe "validate_config/1" do
    test "accepts valid chat completions config" do
      assert :ok =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://dashscope.example.com/v1/chat/completions",
                 "api_key" => "test-key",
                 "model" => "qwen3.7-plus"
               })
    end

    test "requires endpoint, api key, and model" do
      assert {:error, error} = OpenAIChatAdapter.validate_config(%{})
      assert error =~ "endpoint"

      assert {:error, error} =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://example.com/v1/chat/completions",
                 "model" => "qwen3.7-plus"
               })

      assert error =~ "api_key"

      assert {:error, error} =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://example.com/v1/chat/completions",
                 "api_key" => "test-key",
                 "model" => ""
               })

      assert error =~ "model"
    end

    test "rejects invalid endpoint and timeout values" do
      assert {:error, error} =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "not-a-url",
                 "api_key" => "test-key",
                 "model" => "qwen3.7-plus"
               })

      assert error =~ "HTTP/HTTPS"

      assert {:error, error} =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://example.com/v1/chat/completions",
                 "api_key" => "test-key",
                 "model" => "qwen3.7-plus",
                 "timeout" => "0"
               })

      assert error =~ "timeout"
    end
  end

  describe "run/4" do
    test "reports Finch stream transport errors instead of crashing" do
      with_mock Finch,
        build: fn _, _, _, _ -> :request end,
        stream: fn :request, Cympho.Finch, init, _fun, receive_timeout: _timeout ->
          {:error, %Mint.TransportError{reason: :timeout}, init}
        end do
        session_id =
          OpenAIChatAdapter.run(
            %{id: "issue-1", title: "Test issue", description: "Test description"},
            "agent-1",
            self(),
            config: %{
              "endpoint" => "https://dashscope.example.com/compatible-mode/v1",
              "api_key" => "test-key",
              "model" => "qwen3.7-plus",
              "timeout" => 10
            }
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:turn_ended_with_error, ^session_id, {:request_error, "timeout"}}, 1_000
      end
    end
  end
end
