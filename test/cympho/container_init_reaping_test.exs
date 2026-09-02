defmodule Cympho.ContainerInitReapingTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @build_test_path Path.join(@repo_root, "scripts/docker-build-test.sh")
  @dockerfile File.read!(Path.join(@repo_root, "Dockerfile"))
  @probe File.read!(Path.join(@repo_root, "scripts/assert-orphan-reaping.sh"))
  @build_test File.read!(@build_test_path)
  @ci File.read!(Path.join(@repo_root, ".github/workflows/ci.yml"))
  @dockerignore File.read!(Path.join(@repo_root, ".dockerignore"))

  defp final_stage(source) do
    source
    |> String.split(~r/^FROM /m)
    |> List.last()
  end

  test "the final Alpine image installs tini" do
    install_lines =
      @dockerfile
      |> final_stage()
      |> String.split("\n")
      |> Enum.filter(&String.match?(&1, ~r/^RUN apk add(?:\s|$)/))

    assert Enum.any?(install_lines, fn line ->
             line
             |> String.split()
             |> Enum.member?("tini")
           end),
           "the final image must install the tini package"
  end

  test "tini is PID 1 ahead of the release command" do
    entrypoints = Regex.scan(~r/^ENTRYPOINT .*$/m, @dockerfile) |> List.flatten()

    assert entrypoints == [~s(ENTRYPOINT ["/sbin/tini", "--"])]
    assert @dockerfile =~ ~s(CMD ["bin/cympho", "start"])
    assert final_stage(@dockerfile) =~ "ENV HTTP_BIND_IP=0.0.0.0"

    {entrypoint_offset, _length} = :binary.match(@dockerfile, hd(entrypoints))
    {command_offset, _length} = :binary.match(@dockerfile, ~s(CMD ["bin/cympho", "start"]))

    assert entrypoint_offset < command_offset
  end

  test "the release build accepts and compiles in an attested revision" do
    assert @dockerfile =~ "ARG CYMPHO_BUILD_REVISION\n"
    refute @dockerfile =~ "ARG CYMPHO_BUILD_REVISION="
    assert @dockerfile =~ ~s(ENV CYMPHO_BUILD_REVISION=$CYMPHO_BUILD_REVISION)
    assert @dockerfile =~ "grep -Eq '^[0-9a-fA-F]{7,64}$'"
    refute @dockerfile =~ "|unknown"
    assert @build_test =~ ~s(--build-arg "CYMPHO_BUILD_REVISION=$build_revision")
  end

  test "the smoke build labels only an exact committed archive" do
    assert @build_test =~ ~s(rev-parse --verify "HEAD^{commit}")
    assert @build_test =~ "CYMPHO_BUILD_REVISION does not match checkout HEAD"
    assert @build_test =~ ~s(git -C "$repo_root" archive)
    assert @build_test =~ ~s(--output="$context_archive")
    assert @build_test =~ ~r/docker build \\\n(?:.*\\\n)*\s+"\$context_dir"/
    assert @build_test =~ ~s(< "$context_dir/scripts/assert-orphan-reaping.sh")
    assert @build_test =~ ~s(python3 "$context_dir/bin/cympho-health-validator")
  end

  test "the smoke build rejects a caller revision that differs from HEAD" do
    {output, status} =
      System.cmd(@build_test_path, [],
        env: [{"CYMPHO_BUILD_REVISION", String.duplicate("0", 40)}],
        stderr_to_stdout: true
      )

    assert status == 1
    assert output =~ "CYMPHO_BUILD_REVISION does not match checkout HEAD"
  end

  test "the shipped image includes the read-only operator CLI and matching identity" do
    assert @dockerfile =~ "COPY bin bin"
    assert @dockerfile =~ ~s(install -m 0755 bin/cymphoctl "$release_root/bin/cymphoctl")

    assert @dockerfile =~
             ~s(install -m 0755 bin/cympho-health-validator "$release_root/bin/cympho-health-validator")

    assert @dockerfile =~ ~s(> "$release_root/release-info.json")

    final_stage = final_stage(@dockerfile)
    assert final_stage =~ ~r/^RUN apk add .*\bpython3\b/m
    assert final_stage =~ ~r/^RUN apk add .*\bcurl\b/m
  end

  test "the behavioral probe fails closed and verifies the observed pid disappears" do
    assert @probe =~ ~s(if [ "$init_comm" != "tini" ]; then)
    assert @probe =~ "the probe proved nothing"
    assert @probe =~ ~s(if [ "$ppid" = "1" ]; then)
    assert @probe =~ ~s(if [ ! -e "/proc/$gpid" ]; then)
    assert @probe =~ "exit 1"
  end

  test "the Docker build test and CI exercise the behavioral probe" do
    assert @build_test =~ "docker build"
    assert @build_test =~ "docker run --rm -i"
    assert @build_test =~ "scripts/assert-orphan-reaping.sh"
    assert @build_test =~ "bin/cymphoctl readiness --expect-revision"
    assert @build_test =~ "docker port"
    assert @build_test =~ "/api/health"
    assert @build_test =~ "cympho-health-validator"
    assert @ci =~ "scripts/docker-build-test.sh"
  end

  test "the native systemd and DB-only compose deployment is not conflated with image init" do
    compose = File.read!(Path.join(@repo_root, "docker-compose.yml"))
    deploy = File.read!(Path.join(@repo_root, "deploy.sh"))

    refute compose =~ "pids_limit:"
    assert compose =~ "Phoenix app runs natively under"
    assert deploy =~ "systemd"
  end

  test "the Docker context excludes local secrets and generated frontend dependencies" do
    exclusions =
      @dockerignore
      |> String.split("\n", trim: true)
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               ".env",
               ".env.*",
               "config/prod.secret.exs",
               "assets/node_modules"
             ]),
             exclusions
           )
  end
end
