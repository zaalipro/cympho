defmodule Cympho.Adapters.ModelCompatibilityTest do
  use ExUnit.Case, async: true

  alias Cympho.Adapters.ModelCompatibility

  test "allows compatible gateway models" do
    assert :ok =
             ModelCompatibility.validate(:openai_chat, %{
               "endpoint" => "https://dashscope.aliyuncs.com/compatible-mode/v1",
               "model" => "qwen3.6-flash"
             })

    assert :ok =
             ModelCompatibility.validate(:openai_chat, %{
               "endpoint" => "https://openrouter.ai/api/v1",
               "model" => "anthropic/claude-sonnet-4-6"
             })
  end

  test "blocks clear Codex and Claude-family mismatch" do
    assert {:error, message} =
             ModelCompatibility.validate(:codex, %{"model" => "claude-sonnet-4-6"})

    assert message =~ "Codex cannot run Claude-family model"
  end

  test "blocks default Claude Code command with OpenAI-family model" do
    assert {:error, message} =
             ModelCompatibility.validate(:claude_code, %{
               "command" => "claude",
               "model" => "gpt-5.5"
             })

    assert message =~ "default `claude` command"
  end

  test "allows explicit Claude wrapper commands to route custom model names" do
    assert :ok =
             ModelCompatibility.validate(:claude_code, %{
               "command" => "cz",
               "model" => "gpt-5.5"
             })
  end

  test "blocks official OpenAI endpoint with Claude-family model" do
    assert {:error, message} =
             ModelCompatibility.validate(:openai_chat, %{
               "endpoint" => "https://api.openai.com/v1",
               "model" => "claude-opus-4-6"
             })

    assert message =~ "OpenAI chat endpoint"
  end

  test "blocks OpenClaw provider and model prefix mismatch" do
    assert {:error, message} =
             ModelCompatibility.validate(:openclaw, %{
               "provider" => "anthropic",
               "model" => "openai/gpt-5.5"
             })

    assert message =~ "does not match"
  end
end
