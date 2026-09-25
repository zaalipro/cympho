defmodule Cympho.DeploymentPathValidationTest do
  use ExUnit.Case, async: true

  @deploy_script File.read!(Path.expand("../../deploy.sh", __DIR__))

  setup do
    dir = Path.join(System.tmp_dir!(), "cympho-deploy-path-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {canonical, 0} = System.cmd("readlink", ["-f", dir])
    %{dir: String.trim(canonical)}
  end

  test "accepts a regular environment file without substituting its parent", %{dir: dir} do
    file = Path.join(dir, "runtime.env")
    File.write!(file, "fixture=true\n")

    assert {"accepted\n", 0} = validate_file(file)
  end

  test "accepts a not-yet-created environment file under a canonical parent", %{dir: dir} do
    assert {"accepted\n", 0} = validate_file(Path.join(dir, "runtime.env"))
  end

  test "rejects directory and symlink environment files", %{dir: dir} do
    file = Path.join(dir, "runtime.env")
    link = Path.join(dir, "linked.env")
    File.write!(file, "fixture=true\n")
    File.ln_s!(file, link)

    for path <- [dir, link] do
      {output, status} = validate_file(path)
      assert status != 0
      assert output =~ "runtime-env is not a regular non-symlink file: #{path}"
    end
  end

  test "rejects a symlinked environment directory", %{dir: dir} do
    actual = Path.join(dir, "actual")
    alias_path = Path.join(dir, "alias")
    File.mkdir_p!(actual)
    File.ln_s!(actual, alias_path)

    {output, status} = validate_file(Path.join(alias_path, "runtime.env"))

    assert status != 0
    assert output =~ "runtime-env parent is not a canonical directory"
  end

  test "path validators do not mutate their caller's scratch variables", %{dir: dir} do
    script =
      helper_script() <>
        ~S"""
        path=sentinel_path
        label=sentinel_label
        parent=sentinel_parent
        nearest=sentinel_nearest
        canonical=sentinel_canonical
        validate_managed_directory_path "$1" fixture
        [ "$path" = sentinel_path ]
        [ "$label" = sentinel_label ]
        [ "$parent" = sentinel_parent ]
        [ "$nearest" = sentinel_nearest ]
        [ "$canonical" = sentinel_canonical ]
        printf 'unchanged\n'
        """

    assert {"unchanged\n", 0} =
             System.cmd("bash", ["-c", script, "validation-test", dir], stderr_to_stdout: true)
  end

  defp validate_file(file) do
    script =
      helper_script() <>
        ~S"""
        validate_managed_file_path "$1" runtime-env
        printf 'accepted\n'
        """

    System.cmd("bash", ["-c", script, "validation-test", file], stderr_to_stdout: true)
  end

  defp helper_script do
    [_, remote] =
      String.split(@deploy_script, "validate_managed_paths() {\n  run_remote_script <<EOF\n",
        parts: 2
      )

    [helpers, _] =
      String.split(remote, "\nvalidate_managed_directory_path '${DEPLOY_ROOT}'", parts: 2)

    # Expand the real deployment heredoc without executing its privileged callers.
    """
    set -euo pipefail
    _sudo() { "$@"; }
    load_helpers() {
    cat <<EOF
    #{helpers}
    EOF
    }
    eval "$(load_helpers)"
    """
  end
end
