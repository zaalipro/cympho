defmodule Cympho.Adapters.OutputLimitTest do
  use ExUnit.Case, async: false

  alias Cympho.Adapters.OutputLimit

  test "the no-Perl relay streams a bounded large response in blocks" do
    python = System.find_executable("python3")
    dir = Path.join(System.tmp_dir!(), "cympho-relay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.ln_s!(python, Path.join(dir, "python3"))
    old_path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    System.put_env("PATH", dir)

    # This runs the actual wrapper with no Perl in PATH. A one-byte dd relay
    # cannot process the flood within this generous block-I/O deadline.
    {bash, args} =
      OutputLimit.wrapped_command(
        python,
        ["-u", "-c", "import sys; sys.stdout.buffer.write(b'x' * 4000001)"],
        4_000_000
      )

    started = System.monotonic_time(:millisecond)
    {output, status} = System.cmd(bash, args)
    elapsed = System.monotonic_time(:millisecond) - started

    assert status == 0
    assert byte_size(output) == 4_000_001
    assert elapsed < 4_000
  end

  test "the no-Perl relay preserves exact-limit output, prompt input, and command failure" do
    python = System.find_executable("python3")
    dir = Path.join(System.tmp_dir!(), "cympho-relay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.ln_s!(python, Path.join(dir, "python3"))
    old_path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    System.put_env("PATH", dir)

    {bash, args} =
      OutputLimit.wrapped_command(
        python,
        ["-u", "-c", "import sys; sys.stdout.write('ok'); sys.exit(7)"],
        2
      )

    assert {"ok", 7} = System.cmd(bash, args)

    prompt = Path.join(dir, "prompt")
    File.write!(prompt, "input")
    old_prompt = System.get_env("CYMPHO_PROMPT_FILE")
    System.put_env("CYMPHO_PROMPT_FILE", prompt)

    on_exit(fn ->
      if old_prompt,
        do: System.put_env("CYMPHO_PROMPT_FILE", old_prompt),
        else: System.delete_env("CYMPHO_PROMPT_FILE")
    end)

    {bash, args} =
      OutputLimit.wrapped_command(
        python,
        ["-u", "-c", "import sys; sys.stdout.write(sys.stdin.read())"],
        5,
        true
      )

    assert {"input", 0} = System.cmd(bash, args)
  end

  test "the no-Perl relay forwards a drip before the producer finishes" do
    python = System.find_executable("python3")
    dir = Path.join(System.tmp_dir!(), "cympho-relay-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.ln_s!(python, Path.join(dir, "python3"))
    old_path = System.get_env("PATH")

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(dir)
    end)

    System.put_env("PATH", dir)

    gate = Path.join(dir, "release")

    program =
      "import os,sys,time; sys.stdout.write('ready\\n'); sys.stdout.flush(); " <>
        "\nwhile not os.path.exists(sys.argv[1]): time.sleep(.01)\n" <>
        "sys.stdout.write('done')"

    {bash, args} = OutputLimit.wrapped_command(python, ["-u", "-c", program, gate], 10)
    port = Port.open({:spawn_executable, bash}, [:binary, :exit_status, args: args])

    try do
      assert_receive {^port, {:data, "ready\n"}}, 2_000
      File.write!(gate, "go")
      assert_receive {^port, {:data, "done"}}, 2_000
      assert_receive {^port, {:exit_status, 0}}, 2_000
    after
      if Port.info(port), do: Port.close(port)
    end
  end

  test "a missing relay interpreter fails rather than silently accepting truncated output" do
    old_path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", old_path) end)
    System.put_env("PATH", System.tmp_dir!())

    marker =
      Path.join(
        System.tmp_dir!(),
        "cympho-unavailable-relay-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(marker) end)

    {bash, args} =
      OutputLimit.wrapped_command(
        "/bin/sh",
        ["-c", "printf invoked > '#{marker}'; printf complete"],
        2
      )

    {output, status} = System.cmd(bash, args, stderr_to_stdout: true)

    assert status != 0
    assert output =~ "output limiter requires perl or python3"
    refute File.exists?(marker), "the producer started without a safe output relay"
  end

  test "direct adapters inherit a smaller compile-time AgentRunner ceiling" do
    elixir = System.find_executable("elixir")

    code = ~S"""
    Application.put_env(:cympho, :agent_runner_max_output_bytes, 128)
    Code.compile_file("lib/cympho/adapters/output_limit.ex")
    alias Cympho.Adapters.OutputLimit
    IO.write("#{OutputLimit.effective([], %{})}|#{OutputLimit.effective([max_output_bytes: 64], %{"max_output_bytes" => 96})}|#{OutputLimit.effective([max_output_bytes: 1000], %{})}")
    """

    assert {"128|64|128", 0} = System.cmd(elixir, ["-e", code])
    assert OutputLimit.effective([], %{}) == 8_000_000
    assert OutputLimit.effective([max_output_bytes: 32], %{"max_output_bytes" => 64}) == 32
    assert OutputLimit.effective([max_output_bytes: 9_000_000], %{}) == 8_000_000
  end
end
