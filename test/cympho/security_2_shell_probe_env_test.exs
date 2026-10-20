defmodule Cympho.T1Review.Security2ShellProbeEnvTest do
  # Finding security-2: shell probes run agent-writable login dotfiles and
  # ~/.cld with the full BEAM environment.
  use ExUnit.Case, async: false

  alias Cympho.RuntimePreflight

  @sentinel_var "CYMPHO_T1_REVIEW_SERVER_SECRET"

  test "the off-PATH command probe does not hand server env to an agent-writable ~/.cld" do
    # HOME stands in for the agents' writable HOME (deploy: HOME=/opt/cympho/claude-home).
    home = Path.join(System.tmp_dir!(), "t1-review-home-#{System.unique_integer([:positive])}")
    File.mkdir_p!(home)
    leak = Path.join(home, "leak")
    # What a prompt-injected agent could have appended to ~/.cld on an earlier turn.
    File.write!(Path.join(home, ".cld"), "env > '#{leak}'\n")

    sentinel = "server-secret-#{System.unique_integer([:positive])}"
    original_home = System.get_env("HOME")
    System.put_env("HOME", home)
    System.put_env(@sentinel_var, sentinel)

    on_exit(fn ->
      System.put_env("HOME", original_home)
      System.delete_env(@sentinel_var)
      File.rm_rf!(home)
    end)

    # A wrapper command not on the BEAM's PATH (the documented cz/cm setup)
    # makes readiness fall through to the `bash -lc` shell probe.
    command = "t1-review-wrapper-#{System.unique_integer([:positive])}"

    agent = %{
      adapter: :claude_code,
      config: %{"command" => command},
      runtime_config: %{"env" => %{"ANTHROPIC_API_KEY" => "test-key"}}
    }

    assert %{} = RuntimePreflight.for_agent(agent, autonomy_enabled?: false)

    # The probe is synchronous (bounded by its own 2s yield), so ~/.cld ran.
    assert File.exists?(leak)

    # Only the sentinel line is compared, so a failure does not print the
    # rest of the host environment.
    leaked =
      leak
      |> File.read!()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, @sentinel_var <> "="))

    assert leaked == []
  end
end
