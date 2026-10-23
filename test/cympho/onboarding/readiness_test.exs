defmodule Cympho.Onboarding.ReadinessTest do
  use ExUnit.Case, async: true

  alias Cympho.Onboarding.Readiness

  @codex_rates %{"input_usd_per_mtok" => "0.75", "output_usd_per_mtok" => "4.50"}

  describe "check/2 (config/test.exs uses the Fake prober)" do
    test "a found, answering Claude Code passes both server checks" do
      result = Readiness.check("claude_code", %{"command" => "claude"})

      assert result == %{
               "checked" => Readiness.key("claude_code", %{"command" => "claude"}),
               "installed" => true,
               "signed_in" => true
             }

      assert_received {:readiness_prober, :installed?, "claude"}
      assert_received {:readiness_prober, :answers?, "claude_code"}
    end

    test "a missing program is not asked to answer" do
      result = Readiness.check("claude_code", %{"command" => "missing-claude"})

      assert %{"installed" => false, "signed_in" => false} = result
      assert_received {:readiness_prober, :installed?, "missing-claude"}
      refute_received {:readiness_prober, :answers?, _}
    end

    test "a refused test prompt fails the signed-in check" do
      result = Readiness.check("claude_code", %{"command" => "refused-claude"})
      assert %{"installed" => true, "signed_in" => false} = result
    end

    test "Codex is always the codex program" do
      Readiness.check("codex", %{"command" => "ignored", "model" => "gpt-5.4-mini"})
      assert_received {:readiness_prober, :installed?, "codex"}
    end

    test "a runtime onboarding does not offer is never probed" do
      assert %{"installed" => false, "signed_in" => false} = Readiness.check("process", %{})
      refute_received {:readiness_prober, _, _}
    end
  end

  describe "priceable?/2 (the spending limit's own rule)" do
    test "Claude Code reports its cost" do
      assert Readiness.priceable?("claude_code", %{})
    end

    test "Codex needs input and output prices for its model" do
      priced = %{"model" => "gpt-5.4-mini", "pricing" => %{"gpt-5.4-mini" => @codex_rates}}
      assert Readiness.priceable?("codex", priced)

      refute Readiness.priceable?("codex", %{"model" => "gpt-5.4-mini"})

      refute Readiness.priceable?("codex", %{
               "model" => "gpt-5.4-mini",
               "pricing" => %{"gpt-5.4-mini" => %{"input_usd_per_mtok" => "0.75"}}
             })

      refute Readiness.priceable?("codex", %{
               "model" => "gpt-5.5",
               "pricing" => %{"gpt-5.4-mini" => @codex_rates}
             })
    end

    test "runtimes that report no usage cannot be priced" do
      refute Readiness.priceable?("cursor", %{})
      refute Readiness.priceable?("http", %{})
    end
  end

  describe "ready?/3" do
    test "needs a passing result for this exact runtime, and pricing" do
      config = %{"command" => "claude", "model" => "claude-sonnet-5"}
      result = Readiness.check("claude_code", config)

      assert Readiness.ready?(result, "claude_code", config)
      refute Readiness.ready?(result, "claude_code", %{config | "model" => "claude-opus-4-8"})
      refute Readiness.ready?(result, "codex", config)
      refute Readiness.ready?(nil, "claude_code", config)
      refute Readiness.ready?(%{result | "signed_in" => false}, "claude_code", config)
    end

    test "Codex is not ready until its prices are entered" do
      unpriced = %{"command" => "", "model" => "gpt-5.4-mini"}
      result = Readiness.check("codex", unpriced)

      refute Readiness.ready?(result, "codex", unpriced)

      priced = Map.put(unpriced, "pricing", %{"gpt-5.4-mini" => @codex_rates})
      assert Readiness.ready?(result, "codex", priced)
    end
  end

  describe "Shell prober (a stand-in program; no provider is called)" do
    setup do
      dir = Path.join(System.tmp_dir!(), "cympho-readiness-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "finds a program and reads a JSON answer", %{dir: dir} do
      ok =
        fake_program(dir, "ok-claude", ~s({"type":"result","is_error":false,"result":"ready"}), 0)

      refused = fake_program(dir, "refused-claude", ~s({"type":"result","is_error":true}), 0)
      failing = fake_program(dir, "failing-claude", "Invalid API key", 1)

      assert Readiness.Shell.installed?(ok)
      refute Readiness.Shell.installed?(Path.join(dir, "no-such-program"))

      assert Readiness.Shell.answers?("claude_code", ok, "claude-sonnet-5")
      refute Readiness.Shell.answers?("claude_code", refused, nil)
      refute Readiness.Shell.answers?("claude_code", failing, nil)
    end
  end

  defp fake_program(dir, name, output, status) do
    path = Path.join(dir, name)
    File.write!(path, "#!/bin/sh\necho '#{output}'\nexit #{status}\n")
    File.chmod!(path, 0o755)
    path
  end
end
