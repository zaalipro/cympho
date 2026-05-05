defmodule Cympho.Agents.RuntimeEnvTest do
  use ExUnit.Case, async: true

  alias Cympho.Agents.RuntimeEnv

  describe "parse_text/1" do
    test "parses simple KEY=VALUE lines" do
      assert RuntimeEnv.parse_text("FOO=bar\nBAZ=qux") == %{"FOO" => "bar", "BAZ" => "qux"}
    end

    test "ignores blank lines and comments" do
      text = """
      # comment
      ANTHROPIC_BASE_URL=https://api.anthropic.com

      FOO=bar
      """

      assert RuntimeEnv.parse_text(text) == %{
               "ANTHROPIC_BASE_URL" => "https://api.anthropic.com",
               "FOO" => "bar"
             }
    end

    test "preserves = inside the value" do
      assert RuntimeEnv.parse_text("URL=https://x.io/?a=1&b=2") == %{
               "URL" => "https://x.io/?a=1&b=2"
             }
    end

    test "strips a single pair of surrounding quotes" do
      assert RuntimeEnv.parse_text(~s(FOO="bar baz")) == %{"FOO" => "bar baz"}
      assert RuntimeEnv.parse_text("FOO='bar baz'") == %{"FOO" => "bar baz"}
    end

    test "drops malformed lines silently" do
      assert RuntimeEnv.parse_text("no_equals\nFOO=bar\nspace key=v") == %{"FOO" => "bar"}
    end

    test "returns empty map for nil/empty input" do
      assert RuntimeEnv.parse_text(nil) == %{}
      assert RuntimeEnv.parse_text("") == %{}
    end
  end

  describe "to_text/1" do
    test "renders sorted KEY=VALUE lines" do
      text = RuntimeEnv.to_text(%{"B" => "2", "A" => "1"})
      assert text == "A=1\nB=2"
    end

    test "round-trips through parse_text" do
      original = %{"FOO" => "bar", "BAZ" => "qux"}
      assert RuntimeEnv.parse_text(RuntimeEnv.to_text(original)) == original
    end
  end

  describe "from_agent/1" do
    test "extracts env from runtime_config map" do
      agent = %{runtime_config: %{"env" => %{"FOO" => "bar"}}}
      assert RuntimeEnv.from_agent(agent) == %{"FOO" => "bar"}
    end

    test "tolerates atom-keyed env" do
      agent = %{runtime_config: %{env: %{FOO: "bar"}}}
      assert RuntimeEnv.from_agent(agent) == %{"FOO" => "bar"}
    end

    test "returns empty map when runtime_config has no env" do
      assert RuntimeEnv.from_agent(%{runtime_config: %{}}) == %{}
      assert RuntimeEnv.from_agent(%{}) == %{}
      assert RuntimeEnv.from_agent(nil) == %{}
    end
  end
end
