defmodule Cympho.Adapters.OpenAIChatAdapterTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Adapters.OpenAIChatAdapter

  describe "normalize_chat_url/1" do
    test "accepts base endpoints and full chat completions endpoints" do
      assert OpenAIChatAdapter.normalize_chat_url(
               "https://dashscope.example.com/compatible-mode/v1"
             ) ==
               "https://dashscope.example.com/compatible-mode/v1/chat/completions"

      assert OpenAIChatAdapter.normalize_chat_url(
               "https://dashscope.example.com/compatible-mode/v1/"
             ) ==
               "https://dashscope.example.com/compatible-mode/v1/chat/completions"

      assert OpenAIChatAdapter.normalize_chat_url(
               "https://dashscope.example.com/compatible-mode/v1/chat/completions/"
             ) ==
               "https://dashscope.example.com/compatible-mode/v1/chat/completions"
    end

    test "preserves query parameters while normalizing the path" do
      assert OpenAIChatAdapter.normalize_chat_url("https://example.com/v1?region=intl") ==
               "https://example.com/v1/chat/completions?region=intl"

      assert OpenAIChatAdapter.normalize_chat_url(
               "https://example.com/v1/chat/completions?region=intl"
             ) ==
               "https://example.com/v1/chat/completions?region=intl"
    end
  end

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

    test "preserves allowlisted chat usage and adds canonical accounting fields" do
      body =
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => "Done"}}],
          "usage" => %{
            "prompt_tokens" => 1_234,
            "completion_tokens" => 56,
            "total_tokens" => 1_290,
            "api_key" => "must-not-propagate"
          },
          "cost_usd" => "0.0125"
        })

      assert {:ok, result} = OpenAIChatAdapter.parse_chat_response(body)

      assert result["usage"] == %{
               "prompt_tokens" => 1_234,
               "completion_tokens" => 56,
               "total_tokens" => 1_290,
               "input_tokens" => 1_234,
               "output_tokens" => 56
             }

      assert result["cost_usd"] == "0.0125"
      refute Map.has_key?(result["usage"], "api_key")
    end

    test "rejects responses without text content" do
      body = Jason.encode!(%{"choices" => [%{"message" => %{"content" => ""}}]})
      assert {:error, :no_output} = OpenAIChatAdapter.parse_chat_response(body)
    end

    test "falls back to reasoning_content when content is null" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => nil,
                "reasoning_content" => " [owner_update] GLM reasoned the plan. "
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => text}]}} =
               OpenAIChatAdapter.parse_chat_response(body)

      assert text == "[owner_update] GLM reasoned the plan."
    end

    test "falls back to reasoning_content when content is blank" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "",
                "reasoning_content" => "  usable reasoning  "
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "usable reasoning"}]}} =
               OpenAIChatAdapter.parse_chat_response(body)
    end

    test "falls back to reasoning_content when content key is missing" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "reasoning_content" => "reasoning only turn"
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "reasoning only turn"}]}} =
               OpenAIChatAdapter.parse_chat_response(body)
    end

    test "prefers non-empty content over reasoning_content" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "primary content",
                "reasoning_content" => "secondary reasoning"
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "primary content"}]}} =
               OpenAIChatAdapter.parse_chat_response(body)
    end

    test "accepts thinking alias when content is empty" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => "",
                "thinking" => "thought text"
              }
            }
          ]
        })

      assert {:ok, %{"content" => [%{"type" => "text", "text" => "thought text"}]}} =
               OpenAIChatAdapter.parse_chat_response(body)
    end

    test "returns no_output when content is null and reasoning aliases are empty" do
      body =
        Jason.encode!(%{
          "choices" => [
            %{
              "message" => %{
                "content" => nil,
                "reasoning_content" => "   "
              }
            }
          ]
        })

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

      assert :ok =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://example.com/v1/chat/completions",
                 "api_key" => "test-key",
                 "model" => "qwen3.7-plus",
                 "timeout_sec" => 60
               })

      assert {:error, error} =
               OpenAIChatAdapter.validate_config(%{
                 "endpoint" => "https://example.com/v1/chat/completions",
                 "api_key" => "test-key",
                 "model" => "qwen3.7-plus",
                 "timeout" => 30_000,
                 "timeout_sec" => 60
               })

      assert error =~ "disagree"
    end
  end

  describe "run/4" do
    test "uses an evidence-oriented default system prompt" do
      test_pid = self()

      with_mock Finch,
        build: fn :post, url, headers, body ->
          send(test_pid, {:chat_request, url, headers, Jason.decode!(body)})
          :request
        end,
        stream: fn :request, Cympho.Finch, init, fun, receive_timeout: _timeout ->
          body =
            Jason.encode!(%{
              "choices" => [
                %{"message" => %{"content" => "[owner_update] Evidence recorded."}}
              ]
            })

          acc = fun.({:status, 200}, init)
          acc = fun.({:data, body}, acc)
          {:ok, acc}
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

        assert_receive {:chat_request, url, headers, payload}, 1_000
        assert url == "https://dashscope.example.com/compatible-mode/v1/chat/completions"
        assert {"authorization", "Bearer test-key"} in headers

        system_prompt = payload["messages"] |> hd() |> Map.fetch!("content")
        assert system_prompt =~ "Evidence produced"
        assert system_prompt =~ "Evidence inspected"
        assert system_prompt =~ "Restart packet"
        assert system_prompt =~ "do not expose secrets"
        assert system_prompt =~ "cympho-actions JSON only"

        assert_receive {:turn_completed, ^session_id,
                        %{"content" => [%{"text" => "[owner_update] Evidence recorded."}]}},
                       1_000
      end
    end

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

    test "redacts credentials and never returns raw provider error bodies" do
      secret = "sk-provider-secret"

      with_mock Finch,
        build: fn _, _, _, _ -> :request end,
        stream: fn :request, Cympho.Finch, init, fun, receive_timeout: _timeout ->
          body =
            Jason.encode!(%{
              "error" => %{"message" => "Credential #{secret} was rejected"},
              "debug_body" => "raw-provider-body"
            })

          acc = fun.({:status, 401}, init)
          acc = fun.({:data, body}, acc)
          {:ok, acc}
        end do
        session_id =
          OpenAIChatAdapter.run(
            %{id: "issue-1", title: "Test issue", description: "Test description"},
            "agent-1",
            self(),
            config: %{
              "endpoint" => "https://cli.llmotions.com/v1",
              "api_key" => secret,
              "model" => "gpt-5.6-terra",
              "timeout" => 10
            }
          )

        assert_receive {:session_started, ^session_id}, 500

        assert_receive {:turn_ended_with_error, ^session_id,
                        {:http_error, 401, "Credential [REDACTED] was rejected"}},
                       1_000
      end
    end

    test "cancels an in-flight provider request through adapter sessions" do
      test_pid = self()

      with_mock Finch,
        build: fn _, _, _, _ -> :request end,
        stream: fn :request, Cympho.Finch, _init, _fun, receive_timeout: _timeout ->
          send(test_pid, {:provider_request_started, self()})

          receive do
            :finish -> {:ok, %{status: 200, body: []}}
          end
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
              "timeout" => 30_000
            }
          )

        assert_receive {:session_started, ^session_id}, 500
        assert_receive {:provider_request_started, request_pid}, 1_000
        assert Cympho.AdapterSessions.registered?(session_id)

        assert :ok = Cympho.AdapterSessions.cancel(session_id, :operator_stop)

        assert_receive {:turn_ended_with_error, ^session_id, {:cancelled, :operator_stop}},
                       1_000

        refute Process.alive?(request_pid)
        refute_receive {:turn_completed, ^session_id, _result}, 100
      end
    end
  end
end
