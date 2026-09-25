defmodule Cympho.DeploymentSourceSealingTest do
  use ExUnit.Case, async: true
  import Bitwise

  @deploy_script File.read!(Path.expand("../../deploy.sh", __DIR__))
  [_, seal_tail] =
    String.split(
      @deploy_script,
      "run_remote_script <<EOF\n_sudo chown -R root:root ${SOURCE_DIR}\n",
      parts: 2
    )

  [seal_body, _] = String.split(seal_tail, "\nEOF\n", parts: 2)
  @seal_body "_sudo chown -R root:root ${SOURCE_DIR}\n" <> seal_body

  test "seals a mode-0700 synced source while retaining deploy traversal" do
    parent =
      Path.join(System.tmp_dir!(), "cympho-source-seal-#{System.unique_integer([:positive])}")

    source = Path.join(parent, "source")
    child = Path.join(source, "deploy")
    plain_file = Path.join(child, "cympho.service")
    executable = Path.join(source, "build.sh")

    File.mkdir_p!(child)
    File.write!(plain_file, "unit fixture\n")
    File.write!(executable, "#!/bin/sh\n")
    File.chmod!(parent, 0o755)
    File.chmod!(child, 0o755)
    File.chmod!(plain_file, 0o644)
    File.chmod!(executable, 0o755)
    File.chmod!(source, 0o700)

    on_exit(fn ->
      File.chmod(source, 0o700)
      File.chmod(child, 0o755)
      File.rm_rf!(parent)
    end)

    script =
      ~S"""
      set -euo pipefail
      SOURCE_DIR="$1"
      run_remote_script() {
        {
          printf '%s\n' 'set -euo pipefail'
          cat <<'HELPER'
      _sudo() {
        if [ "$1" = chown ]; then
          [ "$2" = -R ] && [ "$3" = root:root ] && [ "$4" = "$EXPECTED_SOURCE" ]
        else
          "$@"
        fi
      }
      HELPER
          cat
        } | EXPECTED_SOURCE="$SOURCE_DIR" bash
      }
      run_remote_script <<EOF
      """ <>
        @seal_body <>
        "\n" <>
        ~S"""
        EOF
        """

    assert {"", 0} =
             System.cmd("bash", ["-c", script, "seal-test", source], stderr_to_stdout: true)

    assert mode(parent) == 0o755
    assert mode(source) == 0o555
    assert mode(child) == 0o555
    assert mode(plain_file) == 0o444
    assert mode(executable) == 0o555
    assert File.read!(plain_file) == "unit fixture\n"
  end

  defp mode(path), do: File.stat!(path).mode &&& 0o777
end
