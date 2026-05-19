defmodule Cympho.Routing.LlmClassifierTest do
  use ExUnit.Case, async: false

  import Mock

  alias Cympho.Routing.LlmClassifier

  setup do
    prior_enabled = Application.get_env(:cympho, :llm_router_enabled?)
    prior_key = Application.get_env(:cympho, :anthropic_api_key)

    Application.put_env(:cympho, :llm_router_enabled?, true)
    Application.put_env(:cympho, :anthropic_api_key, "test-key")

    on_exit(fn ->
      put_or_delete(:llm_router_enabled?, prior_enabled)
      put_or_delete(:anthropic_api_key, prior_key)
    end)

    :ok
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cympho, key)
  defp put_or_delete(key, val), do: Application.put_env(:cympho, key, val)

  defp response_body(role) do
    Jason.encode!(%{
      "id" => "msg",
      "type" => "message",
      "role" => "assistant",
      "content" => [%{"type" => "text", "text" => role}],
      "usage" => %{"input_tokens" => 10, "output_tokens" => 1}
    })
  end

  describe "classify/2" do
    test "happy path returns the LLM-classified role" do
      with_mock Finch,
        build: fn _method, _url, _headers, _body -> :req end,
        request: fn :req, _name, _opts ->
          {:ok, %Finch.Response{status: 200, body: response_body("cto"), headers: []}}
        end do
        assert {:ok, :cto} =
                 LlmClassifier.classify(%{
                   id: Ecto.UUID.generate(),
                   title: "Refactor auth schema",
                   description: "Move sessions to PG"
                 })
      end
    end

    test "returns {:error, :invalid_response} on garbage JSON" do
      with_mock Finch,
        build: fn _m, _u, _h, _b -> :req end,
        request: fn :req, _n, _o ->
          {:ok, %Finch.Response{status: 200, body: "not json", headers: []}}
        end do
        assert {:error, :invalid_response} =
                 LlmClassifier.classify(%{title: "x", description: ""})
      end
    end

    test "returns {:error, :missing_api_key} when no key is configured" do
      Application.delete_env(:cympho, :anthropic_api_key)

      assert {:error, :missing_api_key} =
               LlmClassifier.classify(%{title: "x", description: ""},
                 api_key: nil
               )
    end

    test "returns {:error, :disabled} when the router flag is off" do
      Application.put_env(:cympho, :llm_router_enabled?, false)

      assert {:error, :disabled} =
               LlmClassifier.classify(%{title: "x", description: ""})
    end

    test "tolerates a JSON object response shape" do
      body =
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => ~s({"role": "engineer"})}]
        })

      with_mock Finch,
        build: fn _m, _u, _h, _b -> :req end,
        request: fn :req, _n, _o ->
          {:ok, %Finch.Response{status: 200, body: body, headers: []}}
        end do
        assert {:ok, :engineer} = LlmClassifier.classify(%{title: "x", description: ""})
      end
    end
  end

  describe "configured?/0" do
    test "true when enabled and a key is set" do
      assert LlmClassifier.configured?()
    end

    test "false when disabled" do
      Application.put_env(:cympho, :llm_router_enabled?, false)
      refute LlmClassifier.configured?()
    end

    test "false when no api key" do
      Application.delete_env(:cympho, :anthropic_api_key)
      System.delete_env("ANTHROPIC_API_KEY")
      refute LlmClassifier.configured?()
    end
  end
end
