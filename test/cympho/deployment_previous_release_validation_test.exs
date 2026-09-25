defmodule Cympho.DeploymentPreviousReleaseValidationTest do
  use ExUnit.Case, async: true

  @deploy_script File.read!(Path.expand("../../deploy.sh", __DIR__))
  [_, guard_tail] =
    String.split(@deploy_script, "  if ! run_remote_script <<EOF\ntarget='${PREVIOUS_RELEASE}'\n",
      parts: 2
    )

  [guard_body, _] = String.split(guard_tail, "\nEOF\n  then\n", parts: 2)
  @guard_body "target='${PREVIOUS_RELEASE}'\n" <> guard_body

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "cympho-previous-release-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    {canonical_base, 0} = System.cmd("realpath", [base])
    base = String.trim(canonical_base)
    release = Path.join(base, "release")
    current = Path.join(base, "current")
    File.mkdir_p!(release)
    File.write!(Path.join(release, "release-info.json"), "sealed\n")
    File.chmod!(Path.join(release, "release-info.json"), 0o440)
    File.chmod!(release, 0o550)
    File.ln_s!(release, current)

    on_exit(fn ->
      File.chmod(release, 0o750)
      File.rm_rf!(base)
    end)

    %{release: release, current: current}
  end

  test "accepts a canonical sealed previous release", fixture do
    assert {"validated\n", 0} = validate(fixture)
  end

  test "rejects a writable previous release file", fixture do
    File.chmod!(Path.join(fixture.release, "release-info.json"), 0o640)

    assert {output, status} = validate(fixture)
    assert status != 0
    refute output =~ "validated"
  end

  test "rejects a symlink inside the previous release", fixture do
    File.chmod!(fixture.release, 0o750)
    File.ln_s!("release-info.json", Path.join(fixture.release, "linked-info"))
    File.chmod!(fixture.release, 0o550)

    assert {output, status} = validate(fixture)
    assert status != 0
    refute output =~ "validated"
  end

  test "rejects a changed current release target", fixture do
    File.rm!(fixture.current)
    File.ln_s!(Path.join(Path.dirname(fixture.release), "other-release"), fixture.current)

    assert {output, status} = validate(fixture)
    assert status != 0
    refute output =~ "validated"
  end

  test "rejects an owner outside the trusted root identity", fixture do
    assert {output, status} = validate(fixture, "wrong")
    assert status != 0
    refute output =~ "validated"
  end

  defp validate(%{release: release, current: current}, owner_kind \\ "trusted") do
    script =
      ~S"""
      set -euo pipefail
      PREVIOUS_RELEASE="$1"
      CURRENT_LINK="$2"
      OWNER_KIND="$3"
      APP_USER="$(id -gn)"
      FIXTURE_USER="$(id -un)"
      run_remote_script() {
        {
          printf '%s\n' 'set -euo pipefail'
          cat <<'HELPERS'
      _sudo() {
        case "$1" in
          find)
            shift
            args=("$@")
            for i in "${!args[@]}"; do
              if [ "${args[i]}" = /022 ] && ! command find . -maxdepth 0 -perm /022 -print >/dev/null 2>&1; then
                args[i]=+022
              fi
              if [ "$i" -gt 0 ] && [ "${args[i-1]}" = -user ] && [ "${args[i]}" = root ]; then
                if [ "$OWNER_KIND" = trusted ]; then
                  args[i]="$FIXTURE_USER"
                else
                  args[i]=999999
                fi
              fi
            done
            command find "${args[@]}"
            ;;
          stat)
            [ "$2" = -c ] && [ "$4" = -- ] || return 2
            python3 - "$3" "$5" "$OWNER_KIND" <<'PY'
      import os, stat, sys
      field, path, owner_kind = sys.argv[1:]
      info = os.lstat(path)
      if field == '%a':
          print(format(stat.S_IMODE(info.st_mode), 'o'))
      elif field == '%u':
          print(0 if owner_kind == 'trusted' else 1)
      else:
          raise SystemExit(2)
      PY
            ;;
          *) "$@" ;;
        esac
      }
      HELPERS
          cat
        } | OWNER_KIND="$OWNER_KIND" FIXTURE_USER="$FIXTURE_USER" bash
      }
      if ! run_remote_script <<EOF
      """ <>
        @guard_body <>
        "\n" <>
        ~S"""
        EOF
        then
          exit 1
        fi
        printf 'validated\n'
        """

    System.cmd("bash", ["-c", script, "validation-test", release, current, owner_kind],
      stderr_to_stdout: true
    )
  end
end
