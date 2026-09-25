defmodule Cympho.ReleaseOperatorIntegrationTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @build_dockerfile File.read!(Path.join(@repo_root, "deploy/build.Dockerfile"))
  @deploy_script File.read!(Path.join(@repo_root, "deploy.sh"))
  @validator File.read!(Path.join(@repo_root, "bin/cympho-health-validator"))

  test "the native release carries the CLI and an identity manifest from one build revision" do
    assert @build_dockerfile =~ "ARG CYMPHO_BUILD_REVISION\n"
    refute @build_dockerfile =~ "ARG CYMPHO_BUILD_REVISION="
    assert @build_dockerfile =~ "ENV CYMPHO_BUILD_REVISION=${CYMPHO_BUILD_REVISION}"
    assert @build_dockerfile =~ "grep -Eq '^[0-9a-fA-F]{7,64}$'"
    refute @build_dockerfile =~ "|unknown"
    assert @build_dockerfile =~ "COPY bin bin"
    assert @build_dockerfile =~ ~s(install -m 0755 bin/cymphoctl "$release_root/bin/cymphoctl")

    assert @build_dockerfile =~
             ~s(install -m 0755 bin/cympho-health-validator "$release_root/bin/cympho-health-validator")

    assert @build_dockerfile =~ ~s(> "$release_root/release-info.json")
    assert @build_dockerfile =~ ~s("$app_version" "$CYMPHO_BUILD_REVISION")
  end

  test "deploy supplies, verifies, and probes the exact attested revision" do
    assert @deploy_script =~
             "docker build --build-arg CYMPHO_BUILD_REVISION=${BUILD_REVISION}"

    assert @deploy_script =~ "test -x ${SOURCE_DIR}/_rel/bin/cymphoctl"
    assert @deploy_script =~ ~S|[ "\$manifest_revision" = "${BUILD_REVISION}" ]|

    assert @deploy_script =~
             ~s('${SOURCE_DIR}/bin/cymphoctl' readiness --expect-revision '${BUILD_REVISION}')

    refute @deploy_script =~ ~s(curl -fsS --max-time 10 '${LOCAL_HEALTH_URL}')
    assert @deploy_script =~ ~s(public_readiness_matches)
    assert @deploy_script =~ ~S|python3 "${DEPLOY_CONTEXT}/bin/cympho-health-validator"|
    assert @validator =~ ~S|release["revision"] != expected_revision|
    assert @deploy_script =~ "Public HTTPS readiness verified at revision ${BUILD_REVISION}"

    assert @deploy_script =~
             ~S|rollback_release "Public readiness did not return the exact deployed revision|

    {public_offset, _} = :binary.match(@deploy_script, "Public attested readiness")
    {prune_offset, _} = :binary.match(@deploy_script, "Pruning old releases")
    assert public_offset < prune_offset
  end

  test "deployment rejects an invalid caller-supplied build revision" do
    assert @deploy_script =~
             ~s(if [[ ! "${BUILD_REVISION}" =~ ^[0-9a-fA-F]{7,64}$ ]])

    assert @deploy_script =~
             "CYMPHO_BUILD_REVISION must be a 7-64 character hexadecimal revision"

    assert @deploy_script =~
             ~s(if [[ "${BUILD_REVISION}" != "${SOURCE_REVISION}" ]])

    assert @deploy_script =~
             ~s(git --no-replace-objects -C "${REPO_DIR}" archive --format=tar "${SOURCE_REVISION}^{commit}")

    assert @deploy_script =~ ~s("${DEPLOY_CONTEXT}/" "${DEPLOY_TARGET}:${SOURCE_DIR}/")
    refute @deploy_script =~ "--ignore-submodules"
    assert @deploy_script =~ ~s(git --no-replace-objects -C "${REPO_DIR}" diff --quiet --)

    assert @deploy_script =~
             ~s(git --no-replace-objects -C "${REPO_DIR}" diff --cached --quiet --)

    assert @deploy_script =~
             ~s(git --no-replace-objects -C "${REPO_DIR}" ls-files --others --exclude-standard)

    assert @deploy_script =~ "CYMPHO_SERVICE_NAME must be a simple systemd service name."
    assert @deploy_script =~ "CYMPHO_DEPLOY_ROOT must be a safe absolute path."
    assert @deploy_script =~ "CYMPHO_PREVIEW_DOMAIN must be a distinct bare hostname."

    assert @deploy_script =~
             "CYMPHO_DEPLOY_USER must differ from the untrusted application service user."

    assert @deploy_script =~ "validate_managed_paths"
    assert @deploy_script =~ "validate_managed_directory_path '${DEPLOY_ROOT}' DEPLOY_ROOT"
    assert @deploy_script =~ "validate_managed_file_path '${ENV_FILE}' runtime-env"
    assert @deploy_script =~ "validate_managed_file_path '${DB_ENV_FILE}' database-env"
    assert @deploy_script =~ "Validating managed deployment paths"
    assert @deploy_script =~ "SOURCE_DIR_SAFE=0"
    assert @deploy_script =~ ~s(if [[ "${SOURCE_DIR_SAFE}" == "1")
    assert @deploy_script =~ "cleanup_remote_source_dir"
    assert @deploy_script =~ ~S|base=\${source##*/}|
    assert @deploy_script =~ ~S|^${BUILD_REVISION:0:12}-[0-9a-f]{8}\$|
    assert @deploy_script =~ "validate_deploy_service_account"
    assert @deploy_script =~ ~S|groups=\$(id -G ${APP_USER})|
    assert @deploy_script =~ "Application service account must not have supplementary groups."
    assert @deploy_script =~ "Application service group must not have named members."
    assert @deploy_script =~ "Application service group must not be shared by another account."
    assert @deploy_script =~ "Application service group GID must not have another group alias."

    assert @deploy_script =~
             "Application service account UID must not be shared by another username."

    assert @deploy_script =~ ~S|deploy_uid=\$(id -u ${DEPLOY_USER})|

    assert @deploy_script =~
             "Application service account UID must differ from the deploy operator UID."

    assert @deploy_script =~ ~s(chown -R root:root ${SOURCE_DIR})
    assert @deploy_script =~ ~s(chmod -R a-w ${SOURCE_DIR})
  end

  test "deployment supports the local HTTPS assertion and release CLI dependency" do
    assert @deploy_script =~ "CYMPHO_TRUSTED_PROXY_IPS=127.0.0.1,::1"
    assert @deploy_script =~ "-v app_host='${DOMAIN}'"
    assert @deploy_script =~ "-v port='${APP_PORT}'"
    assert @deploy_script =~ "-v bind_ip='127.0.0.1'"
    assert @deploy_script =~ "-v proxies='127.0.0.1,::1'"
    assert @deploy_script =~ "python3 required (operator readiness validator)"
    assert @deploy_script =~ "systemd-run required (migration runner)"
    assert @deploy_script =~ "bash required (operator CLI)"
    assert @deploy_script =~ "curl required (readiness probe)"
    assert @deploy_script =~ "--property=EnvironmentFile=${ENV_FILE}"
    refute @deploy_script =~ ~S|source ${ENV_FILE}|
  end

  test "post-cutover proxy failures use the same exact-revision rollback path" do
    assert @deploy_script =~
             ~S(run_remote_script <<EOF || rollback_release "Failed to configure nginx/TLS")
  end

  test "rollback is not reported successful without probing its recorded exact revision" do
    assert @deploy_script =~ "PREVIOUS_REVISION="

    assert @deploy_script =~
             ~s(readiness --expect-revision '${PREVIOUS_REVISION}' >/dev/null)

    assert @deploy_script =~
             ~s(CYMPHOCTL_HEALTH_VALIDATOR='${SOURCE_DIR}/bin/cympho-health-validator')

    assert @deploy_script =~
             ~s('${SOURCE_DIR}/bin/cymphoctl' readiness --expect-revision '${PREVIOUS_REVISION}')

    refute @deploy_script =~
             ~s('${CURRENT_LINK}/bin/cymphoctl' readiness --expect-revision '${PREVIOUS_REVISION}')

    assert @deploy_script =~
             "Rollback readiness verified at revision ${PREVIOUS_REVISION}."

    assert @deploy_script =~
             "CRITICAL: rollback did not become ready at its recorded revision."

    assert @deploy_script =~
             "Cutover had not occurred; verifying the unchanged previous release."

    assert @deploy_script =~
             "current release changed unexpectedly; refusing to overwrite it during rollback."

    assert @deploy_script =~
             "This verifies boot compatibility only; database migrations were not reversed."
  end

  test "a failed first deployment is stopped and detached instead of left serving" do
    assert @deploy_script =~ "No previous release exists; stopping the failed first deployment."
    assert @deploy_script =~ ~s(sudo systemctl stop '${SERVICE_NAME}')
    assert @deploy_script =~ ~s(sudo rm -f -- '${CURRENT_LINK}')

    assert @deploy_script =~
             "CRITICAL: no previous release was available; service recovery is required."

    assert @deploy_script =~ "Cutover had not occurred and no prior service state was changed."
  end

  test "release identity and validation tools remain outside service write authority" do
    unit = File.read!(Path.join(@repo_root, "deploy/cympho.service"))

    refute unit =~ "ReadWritePaths=/opt/cympho\n"

    assert unit =~
             "ReadWritePaths=/opt/cympho/data/uploads /opt/cympho/data/import-transfers /opt/cympho/claude-home"

    assert @deploy_script =~ ~s(install -d -m 0755 -o root -g root ${RELEASES_DIR})

    assert @deploy_script =~
             ~s(install -d -m 0700 -o ${DEPLOY_USER} -g ${DEPLOY_USER} ${SOURCE_DIR}/_rel)

    assert @deploy_script =~ ~s(install -d -m 0700 -o root -g root ${RELEASE_DIR})
    assert @deploy_script =~ ~s(chown -R root:${APP_USER} ${SOURCE_DIR}/_rel)
    assert @deploy_script =~ ~s(chmod -R u=rX,g=rX,o= ${SOURCE_DIR}/_rel)
    assert @deploy_script =~ ~s(chmod 0440 ${SOURCE_DIR}/_rel/releases/COOKIE)
    assert @deploy_script =~ ~s(chown -R root:${APP_USER} ${RELEASE_DIR})
    assert @deploy_script =~ ~s(chmod -R u=rX,g=rX,o= ${RELEASE_DIR})
    assert @deploy_script =~ ~s(chown root:${APP_USER} ${RELEASE_DIR}/releases/COOKIE)
    assert @deploy_script =~ ~s(chmod 0440 ${RELEASE_DIR}/releases/COOKIE)
    refute @deploy_script =~ ~s(chown -R ${APP_USER}:${APP_USER} ${RELEASE_DIR})
    assert @deploy_script =~ ~s(test -L ${DEPLOY_ROOT}/bin)
    assert @deploy_script =~ ~s(test -L ${DEPLOY_ROOT}/bin/claude)

    assert @deploy_script =~
             ~s(chown --no-dereference root:root ${DEPLOY_ROOT}/bin/claude)

    refute @deploy_script =~ ~s(sudo -u '${APP_USER}' env CYMPHOCTL_SERVICE_NAME)

    assert @deploy_script =~
             ~s(CYMPHOCTL_HEALTH_VALIDATOR='${SOURCE_DIR}/bin/cympho-health-validator')
  end

  test "legacy release data is constrained and parsed only by trusted new tooling" do
    assert @deploy_script =~
             ~S"^/opt/cympho/releases/([0-9]{14}|[0-9]{14}-[0-9a-f]{12}-[0-9a-f]{8})$"

    assert @deploy_script =~ ~S(_sudo test ! -L "\$target")
    assert @deploy_script =~ ~S(_sudo test -d "\$target")
    assert @deploy_script =~ ~S(_sudo stat -c %u -- "\$target")
    assert @deploy_script =~ ~S(_sudo test "\$owner" = 0)
    refute @deploy_script =~ "app_uid="
    assert @deploy_script =~ ~S(_sudo find "\$target" -type l -print -quit)
    assert @deploy_script =~ ~S|_sudo find "\$target" \\( ! -user root -o -perm /022 \\)|
    assert @deploy_script =~ ~S|_sudo find "\$target" ! -group ${APP_USER} -print -quit|
    assert @deploy_script =~ ~S|case "\$mode" in|
    assert @deploy_script =~ "440|550"

    assert @deploy_script =~
             ~s(sudo python3 '${SOURCE_DIR}/bin/cympho-health-validator' release-revision '${PREVIOUS_RELEASE}/release-info.json')

    assert @deploy_script =~ ~s(if [[ ! "${PREVIOUS_REVISION}" =~ ^[0-9a-fA-F]{7,64}$ ]])

    assert @deploy_script =~
             ~s|${PREVIOUS_RELEASE}/bin/${APP_NAME} eval 'IO.write(Cympho.BuildInfo.revision())'|

    assert @deploy_script =~ ~S([[ "${PREVIOUS_COMPILED_REVISION}" != "${PREVIOUS_REVISION}" ]])
    refute @deploy_script =~ ~s(python3 - '${PREVIOUS_RELEASE}/release-info.json')
    refute @deploy_script =~ ~s('${CURRENT_LINK}/bin/cympho-health-validator')

    assert @deploy_script =~ "Cympho.BuildInfo.revision()"
    assert @deploy_script =~ "--property=RuntimeMaxSec=30s"

    assert @deploy_script =~ ~s(_sudo systemctl show '${SERVICE_NAME}' -p MainPID --value)
    assert @deploy_script =~ "Readiness accepted only while MainPID remains active"

    assert @deploy_script =~
             ~s(cympho-health-validator' release-revision '${SOURCE_DIR}/_rel/release-info.json')

    assert @deploy_script =~ ~S([ "\$manifest_revision" = "\$compiled_revision" ])

    assert @deploy_script =~
             "compiled release identity does not match the requested build revision"

    assert :binary.match(@deploy_script, "Cympho.BuildInfo.revision()") <
             :binary.match(@deploy_script, ~s(Cympho.Release.migrate))

    assert :binary.match(@deploy_script, "PREVIOUS_COMPILED_REVISION=") <
             :binary.match(@deploy_script, ~s(step "Snapshotting runtime environment"))
  end

  test "one required host flock spans shared build and cutover state" do
    assert @deploy_script =~
             "sudo flock ${lock_args} --conflict-exit-code 75 '${DEPLOY_SESSION_LOCK}'"

    assert @deploy_script =~ ~s(DEPLOY_SESSION_LOCK="/var/lock/cympho-deploy.lock")

    assert @deploy_script =~ "Refusing concurrent deploy"
    assert @deploy_script =~ "Remote deploy lock holder exited; refusing to continue unlocked."
    assert @deploy_script =~ "acquire_deploy_lock"
    assert @deploy_script =~ "require_deploy_lock"
    assert @deploy_script =~ ~S|kill -TERM "${DEPLOY_MAIN_PID}"|
    assert @deploy_script =~ ~S|DEPLOY_LOCK_MONITOR_PID=$!|
    assert @deploy_script =~ ~s(kill "${DEPLOY_LOCK_PID}")
    assert @deploy_script =~ ~s(wait "${DEPLOY_LOCK_PID}")

    assert @deploy_script =~
             ~s(BUILD_IMAGE_TAG="${APP_NAME}-build:${BUILD_REVISION:0:12}-${DEPLOY_NONCE}")

    assert @deploy_script =~
             ~S|RELEASE_ID="$(date -u +%Y%m%d%H%M%S)-${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"|

    assert @deploy_script =~
             ~S|SOURCE_DIR="${SOURCES_DIR}/${BUILD_REVISION:0:12}-${DEPLOY_NONCE}"|

    assert @deploy_script =~
             "Current release changed after this deploy began; refusing a stale cutover."

    assert @deploy_script =~ "trap cleanup_build EXIT"
    assert @deploy_script =~ ~S|docker image rm "\$image"|
    assert @deploy_script =~ "cleanup_remote_source_dir"
    assert @deploy_script =~ ~S|_sudo rm -rf -- "\$source"|
  end

  test "hardcoded unit identity and paths cannot be silently overridden" do
    assert @deploy_script =~
             "This deployment unit requires app/service/user cympho, /opt/cympho, /etc/cympho.env, and port 4000."

    assert @deploy_script =~ ~S|"${APP_NAME}" != "cympho"|
    assert @deploy_script =~ ~S|"${APP_USER}" != "cympho"|
    assert @deploy_script =~ ~S|"${SERVICE_NAME}" != "cympho"|
    assert @deploy_script =~ ~S|"${DEPLOY_ROOT}" != "/opt/cympho"|
    assert @deploy_script =~ ~S|"${ENV_FILE}" != "/etc/cympho.env"|
    assert @deploy_script =~ ~S|"${APP_PORT}" != "4000"|
  end
end
