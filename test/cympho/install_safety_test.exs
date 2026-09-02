defmodule Cympho.InstallSafetyTest do
  use ExUnit.Case, async: true

  test "production installer preserves credentials and requires an interactive terminal" do
    assert {"install safety tests passed\n", 0} =
             System.cmd("bash", ["test/shell/install_safety_test.sh"], stderr_to_stdout: true)

    installer = File.read!("install.sh")
    assert installer =~ "EnvironmentFile=$env_file"
    refute installer =~ ~S(source "$APP_DIR/.env")
    assert installer =~ "production_build_revision"
    assert installer =~ ~s(git --no-replace-objects -C "$repo_dir" diff --quiet --)
    assert installer =~ "CYMPHO_BUILD_REVISION=$BUILD_REVISION"
    assert installer =~ ~s(export CYMPHO_BUILD_REVISION="$BUILD_REVISION")
    assert installer =~ "stage_production_source_snapshot"

    assert installer =~
             ~s(git --no-replace-objects -C "$repo_dir" archive --format=tar --output="$archive_file" "$revision")

    assert installer =~ ~s(cd -- "$PRODUCTION_SOURCE_STAGE")

    assert installer =~
             ~s(seal_production_source_snapshot "$PRODUCTION_SOURCE_STAGE" "$SERVICE_GROUP")

    assert installer =~ "mix compile --force"
    assert installer =~ "mix release --overwrite"

    assert installer =~
             ~s(install_release_operator_tools "$PRODUCTION_SOURCE_STAGE" "$BUILD_REVISION")

    assert installer =~ "SERVICE_USER=cympho"
    assert installer =~ "SERVICE_GROUP=cympho"
    assert installer =~ ~s(ensure_production_service_account "$SERVICE_USER" "$SERVICE_GROUP")
    refute installer =~ ~S|USER=$(id -un)|
    assert installer =~ ~s(export MIX_BUILD_PATH="$PRODUCTION_SOURCE_STAGE/_build")
    assert installer =~ ~s(export MIX_DEPS_PATH="$PRODUCTION_SOURCE_STAGE/deps")

    assert installer =~
             ~s(validate_production_release_payload "$PRODUCTION_SOURCE_STAGE" "$BUILD_REVISION")

    assert installer =~ "subprocess.Popen"
    assert installer =~ "process.communicate(timeout=10)"
    refute installer =~ "command_exists timeout"

    assert installer =~ "PRODUCTION_SOURCE_PUBLISHED=1"
    assert installer =~ "Verifying exact production revision readiness"

    assert installer =~
             ~s("$APP_DIR/_build/prod/rel/cympho/bin/cymphoctl" readiness --expect-revision "$BUILD_REVISION")

    assert installer =~ ~s(run_as_service_user "$SERVICE_USER" env)
    assert installer =~ ~s(run_as_root systemctl is-active --quiet cympho)
    assert installer =~ ~s(systemctl show -p MainPID --value cympho)

    refute installer =~
             ~s("$APP_DIR/bin/cymphoctl" readiness --expect-revision "$BUILD_REVISION")

    assert installer =~ "Production release did not become ready at the attested revision."
    assert installer =~ "Python 3 is required to validate the production release manifest."
    assert installer =~ ~r/apt-get install -y[^\n]*\bpython3\b/
    assert installer =~ "CYMPHO_UPLOADS_DIR=/var/lib/cympho/data/uploads"

    assert installer =~
             "CYMPHO_IMPORT_SPOOL_DIR=/var/lib/cympho/data/import-transfers"

    assert installer =~ "prepare_production_runtime_directories"
    assert installer =~ "ExecStart=$app_dir/_build/prod/rel/cympho/bin/cympho start"
    assert installer =~ "PrivateTmp=true"
    assert installer =~ ~s(CYMPHOCTL_APP_HOST="$DOMAIN")
    refute installer =~ "exec mix phx.server"

    {export_offset, _} =
      :binary.match(installer, ~s(export CYMPHO_BUILD_REVISION="$BUILD_REVISION"))

    {compile_offset, _} = :binary.match(installer, "mix compile --force")
    assert export_offset < compile_offset

    {runtime_env_offset, _} =
      :binary.match(installer, "CYMPHO_IMPORT_SPOOL_DIR=/var/lib/cympho/data/import-transfers")

    assert runtime_env_offset < compile_offset
    {secret_env_offset, _} = :binary.match(installer, "SECRET_KEY_BASE=$SECRET_KEY_BASE")
    assert secret_env_offset < compile_offset

    {stage_offset, _} = :binary.match(installer, ~s(cd -- "$PRODUCTION_SOURCE_STAGE"))
    assert stage_offset < compile_offset

    {release_offset, _} = :binary.match(installer, "mix release --overwrite")

    {artifact_validation_offset, _} =
      :binary.match(
        installer,
        ~s(validate_production_release_payload "$PRODUCTION_SOURCE_STAGE" "$BUILD_REVISION")
      )

    {setup_offset, _} = :binary.match(installer, "mix setup")

    {seal_offset, _} =
      :binary.match(
        installer,
        ~s(seal_production_source_snapshot "$PRODUCTION_SOURCE_STAGE" "$SERVICE_GROUP")
      )

    {restart_offset, _} = :binary.match(installer, "run_as_root systemctl restart cympho")
    {activated_offset, _} = :binary.match(installer, "PRODUCTION_SOURCE_ACTIVATED=1")
    assert compile_offset < seal_offset
    assert release_offset < seal_offset
    assert artifact_validation_offset < setup_offset
    assert seal_offset < restart_offset
    assert restart_offset < activated_offset

    {account_preflight_offset, _} =
      :binary.match(
        installer,
        ~s(ensure_production_service_account "$SERVICE_USER" "$SERVICE_GROUP")
      )

    {bootstrap_refusal_offset, _} =
      :binary.match(
        installer,
        "require_fresh_production_bootstrap /etc/systemd/system/cympho.service"
      )

    {database_mutation_offset, _} = :binary.match(installer, "if ! provision_production_database")
    {caddy_activation_offset, _} = :binary.match(installer, ~s(configure_cympho_caddy "$DOMAIN"))
    {package_mutation_offset, _} = :binary.match(installer, "run_as_root apt-get update -y")
    assert bootstrap_refusal_offset < account_preflight_offset
    assert bootstrap_refusal_offset < package_mutation_offset
    assert bootstrap_refusal_offset < database_mutation_offset
    assert bootstrap_refusal_offset < caddy_activation_offset
    assert account_preflight_offset < database_mutation_offset
    assert account_preflight_offset < caddy_activation_offset
    assert restart_offset < caddy_activation_offset
  end

  test "README downloads the repository before invoking the interactive installer" do
    readme = File.read!("README.md")

    assert readme =~ "git clone https://github.com/zaalipro/cympho.git"
    assert readme =~ "./install.sh"
    assert readme =~ "Do not pipe it into a shell"
    assert readme =~ "exact Git archive"
    assert readme =~ "Persistent uploads/import data"
    refute readme =~ ~r/curl[^\n|]*\|\s*(?:ba)?sh/
  end
end
