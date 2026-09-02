#!/usr/bin/env bash
set -e

install_error() {
    echo "Error: $*" >&2
    return 1
}

# install.sh is deliberately a first-bootstrap helper on production Linux.
# Existing managed service state belongs to deploy.sh, which has the
# transactional release/rollback machinery. Treat any directory entry at the
# unit path as existing, including symlinks whose target is currently absent.
require_fresh_production_bootstrap() {
    local unit_path=$1

    if [ -L "$unit_path" ] || [ -e "$unit_path" ]; then
        install_error "Production install.sh is first-bootstrap-only once a managed cympho systemd unit exists; there is no managed in-place updater. deploy.sh is a separate fixed-layout workflow, not an upgrade continuation."
        return 1
    fi
}

require_interactive_terminal() {
    if [ ! -t 0 ]; then
        install_error "This installer is interactive. Clone or download Cympho, then run ./install.sh from a terminal."
    fi
}

prompt_install_type() {
    echo "Are you installing this for Local Development or Production VPS?"

    select INST_TYPE in "Local" "Production"; do
        case $INST_TYPE in
            Local ) IS_PROD=0; break;;
            Production ) IS_PROD=1; break;;
        esac
    done
}

# Reports only installation state; it never reads or prints credentials.
production_env_state() {
    local env_file=$1

    if [ -L "$env_file" ]; then
        install_error "$env_file must be a regular, non-symlink file."
    elif [ ! -e "$env_file" ]; then
        printf '%s\n' "new"
    elif [ ! -f "$env_file" ]; then
        install_error "$env_file must be a regular, non-symlink file."
    else
        printf '%s\n' "existing"
    fi
}

# Production compiles must be tied to one immutable, clean Git checkout. This
# keeps the compile-time BuildInfo revision and the source that the service
# runs from the same exact commit. Replacement refs are ignored so attestation
# and archive materialization always address the original object.
production_build_revision() {
    local repo_dir=${1:-.}
    local revision

    if ! command_exists git; then
        install_error "git is required to derive the production build revision."
        return 1
    fi

    revision=$(git --no-replace-objects -C "$repo_dir" rev-parse --verify "HEAD^{commit}" 2>/dev/null) || {
        install_error "Production requires a Git checkout with an exact HEAD commit."
        return 1
    }

    if [[ ! "$revision" =~ ^[0-9a-fA-F]{7,64}$ ]] ||
       ! git --no-replace-objects -C "$repo_dir" diff --quiet -- ||
       ! git --no-replace-objects -C "$repo_dir" diff --cached --quiet -- ||
       [ -n "$(git --no-replace-objects -C "$repo_dir" ls-files --others --exclude-standard)" ]; then
        install_error "Production requires a clean Git checkout with no local changes."
        return 1
    fi

    printf '%s\n' "${revision,,}"
}

validate_production_tree_ancestors() {
    local root=$1
    shift
    local canonical current path component relative

    canonical=$(cd -- "$root" 2>/dev/null && pwd -P) || return 1
    if [ "$canonical" != "$root" ] || [ -L "$root" ]; then
        install_error "Production release ancestors must be canonical non-symlink directories."
        return 1
    fi
    for path in "$@"; do
        case "$path" in
            "$root"/*) relative=${path#"$root"/} ;;
            *) install_error "Production release path must remain inside its source snapshot."; return 1 ;;
        esac
        current=$root
        IFS=/ read -r -a components <<<"$relative"
        for component in "${components[@]}"; do
            current="$current/$component"
            if [ -L "$current" ] || [ ! -d "$current" ]; then
                install_error "Production release ancestors must be canonical non-symlink directories."
                return 1
            fi
            canonical=$(cd -- "$current" 2>/dev/null && pwd -P) || return 1
            if [ "$canonical" != "$current" ]; then
                install_error "Production release ancestors must be canonical non-symlink directories."
                return 1
            fi
        done
    done
}

# Materialize the attested Git object into a separate tree before any build
# work. Production compilation and the long-running service both use this
# snapshot, so a later checkout mutation cannot change the bytes that were
# reviewed and embedded in BuildInfo. The destination is root-owned and
# read-only after publication; the caller keeps mutable state (such as .env)
# outside this tree.
seal_production_source_snapshot() {
    local snapshot_dir=$1
    local service_group=${2:-cympho}
    local release_cookie="$snapshot_dir/_build/prod/rel/cympho/releases/COOKIE"
    local release_root="$snapshot_dir/_build/prod/rel/cympho"

    if [ -z "$snapshot_dir" ] || [ ! -d "$snapshot_dir" ]; then
        install_error "Production source snapshot is missing."
        return 1
    fi
    if [[ ! "$service_group" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        install_error "Production service group is invalid."
        return 1
    fi
    validate_production_tree_ancestors "$snapshot_dir" "$release_root" || return 1
    if run_as_root test -L "$release_cookie" || ! run_as_root test -f "$release_cookie"; then
        install_error "Production release cookie is missing or unsafe."
        return 1
    fi

    run_as_root chown -R "root:$service_group" "$snapshot_dir" || return 1
    run_as_root chmod -R u=rX,g=rX,o= "$snapshot_dir" || return 1
    run_as_root chown "root:$service_group" "$release_cookie" || return 1
    run_as_root chmod 0440 "$release_cookie" || return 1
}

validate_production_release_payload() {
    local source_dir=$1
    local expected_revision=$2
    local release_bin="$source_dir/_build/prod/rel/cympho/bin/cympho"
    local release_root="$source_dir/_build/prod/rel/cympho"
    local observed_revision
    local manifest_revision

    if ! command_exists python3; then
        install_error "Python 3 is required to validate the production release manifest."
        return 1
    fi

    validate_production_tree_ancestors "$source_dir" "$release_root" || return 1

    if find -P "$release_root" -type l -print -quit 2>/dev/null | grep -q .; then
        install_error "Production release payload must not contain symlinks."
        return 1
    fi

    if [ ! -f "$release_bin" ] || [ ! -x "$release_bin" ] || [ -L "$release_bin" ]; then
        install_error "Production release payload is missing or unsafe."
        return 1
    fi

    observed_revision=$(python3 - "$release_bin" <<'PY'
import os
import signal
import subprocess
import sys

try:
    process = subprocess.Popen(
        [sys.argv[1], "eval", "IO.write(Cympho.BuildInfo.revision())"],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        raise SystemExit(1)
    if process.returncode != 0:
        raise SystemExit(1)
    sys.stdout.write(output)
except (OSError, ValueError):
    raise SystemExit(1)
PY
    ) || {
        install_error "Production release identity could not be verified."
        return 1
    }
    if [ "$observed_revision" != "$expected_revision" ]; then
        install_error "Production release identity does not match the attested source revision."
        return 1
    fi

    for tool in cymphoctl cympho-health-validator; do
        if [ ! -f "$release_root/bin/$tool" ] || [ ! -x "$release_root/bin/$tool" ] ||
           [ -L "$release_root/bin/$tool" ]; then
            install_error "Production release operator tooling is missing or unsafe."
            return 1
        fi
    done

    if [ ! -f "$release_root/release-info.json" ] || [ -L "$release_root/release-info.json" ]; then
        install_error "Production release identity manifest is missing or unsafe."
        return 1
    fi
    manifest_revision=$(python3 "$source_dir/bin/cympho-health-validator" \
        release-revision "$release_root/release-info.json") || {
        install_error "Production release identity manifest is invalid."
        return 1
    }
    [ "$manifest_revision" = "$expected_revision" ] || {
        install_error "Production release identity manifest does not match the attested source revision."
        return 1
    }
}

install_release_operator_tools() {
    local source_dir=$1
    local expected_revision=$2
    local release_root="$source_dir/_build/prod/rel/cympho"
    local app_version
    local release_info="$release_root/release-info.json"
    local staged_info
    validate_production_tree_ancestors "$source_dir" "$release_root/bin" || return 1

    app_version=$(awk -F'"' '/version: "/ { print $2; exit }' "$source_dir/mix.exs") || return 1
    [ -n "$app_version" ] || return 1
    for tool in cymphoctl cympho-health-validator; do
        local tool_path="$release_root/bin/$tool"
        if [ -L "$tool_path" ] || { [ -e "$tool_path" ] && [ ! -f "$tool_path" ]; }; then
            install_error "$tool_path must be a regular, non-symlink file."
            return 1
        fi
    done
    install -m 0755 "$source_dir/bin/cymphoctl" "$release_root/bin/cymphoctl" || return 1
    install -m 0755 "$source_dir/bin/cympho-health-validator" \
        "$release_root/bin/cympho-health-validator" || return 1
    if [ -L "$release_info" ] || { [ -e "$release_info" ] && [ ! -f "$release_info" ]; }; then
        install_error "$release_info must be a regular, non-symlink file."
        return 1
    fi
    staged_info=$(mktemp "$release_root/.release-info.json.tmp.XXXXXX") || return 1
    printf '{"schema_version":1,"service":"cympho","release":{"version":"%s","revision":"%s"}}\n' \
        "$app_version" "$expected_revision" > "$staged_info" || {
        rm -f "$staged_info"
        return 1
    }
    if [ -e "$release_info" ]; then
        mv -f -- "$staged_info" "$release_info"
    elif ! ln "$staged_info" "$release_info"; then
        rm -f "$staged_info"
        install_error "$release_info appeared during installation; refusing to replace it."
        return 1
    else
        rm -f "$staged_info"
    fi
}

stage_production_source_snapshot() {
    local repo_dir=$1
    local revision=$2
    local destination=${3:-/var/lib/cympho/source/$revision}
    local parent
    local archive_file
    local snapshot_stage
    local installer_uid
    local installer_gid
    local source_tree

    if [[ ! "$revision" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
        install_error "Cannot stage production source with an invalid Git revision."
        return 1
    fi

    source_tree=$(git --no-replace-objects -C "$repo_dir" ls-tree -r "$revision") || {
        install_error "Cannot inspect the attested production source tree."
        return 1
    }
    if printf '%s\n' "$source_tree" | awk '$1 == "120000" { found = 1 } END { exit !found }'; then
        install_error "Production source snapshot must not contain symlinks."
        return 1
    fi

    if [[ ! "$destination" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
       [[ "$destination" == *"//"* || "$destination" == */.. || "$destination" == *"/../"* ]]; then
        install_error "Production source snapshot path must be a safe absolute path."
        return 1
    fi

    parent=$(dirname -- "$destination")
    if [[ "$destination" == /var/lib/cympho/source/* ]] && [ "$(uname -s)" = Linux ]; then
        local managed_ancestor managed_canonical managed_owner managed_writable
        for managed_ancestor in /var/lib/cympho /var/lib/cympho/source; do
            if run_as_root test -L "$managed_ancestor" ||
               { run_as_root test -e "$managed_ancestor" &&
                 ! run_as_root test -d "$managed_ancestor"; }; then
                install_error "Production source ancestors must be canonical directories."
                return 1
            fi
            run_as_root install -d -m 0755 -o root -g root "$managed_ancestor" || return 1
            run_as_root chown root:root "$managed_ancestor" || return 1
            run_as_root chmod 0755 "$managed_ancestor" || return 1
            managed_canonical=$(run_as_root readlink -f -- "$managed_ancestor") || return 1
            managed_owner=$(run_as_root stat -c %u -- "$managed_ancestor") || return 1
            managed_writable=$(run_as_root find "$managed_ancestor" -prune -perm /022 -print) || return 1
            if [ "$managed_canonical" != "$managed_ancestor" ] ||
               [ "$managed_owner" != 0 ] || [ -n "$managed_writable" ]; then
                install_error "Production source ancestor is not root-owned and non-writable."
                return 1
            fi
        done
    fi
    local existing_parent=$parent
    while [ ! -e "$existing_parent" ] && [ "$existing_parent" != "/" ]; do
        existing_parent=$(dirname -- "$existing_parent")
    done
    if run_as_root test -L "$destination" || run_as_root test -L "$parent" ||
       run_as_root test ! -d "$existing_parent" ||
       [ "$(cd -- "$existing_parent" 2>/dev/null && pwd -P)" != "$existing_parent" ]; then
        install_error "Production source snapshot destination must not be a symlink."
        return 1
    fi

    run_as_root install -d -m 0755 -o root -g root "$parent" || return 1
    run_as_root chown root:root "$parent" || return 1
    run_as_root chmod 0755 "$parent" || return 1

    if [ "$(cd -- "$parent" && pwd -P)" != "$parent" ]; then
        install_error "Production source snapshot parent must be canonical."
        return 1
    fi

    if run_as_root test -e "$destination"; then
        install_error "Production source snapshot already exists at $destination."
        return 1
    fi

    archive_file=$(mktemp "${TMPDIR:-/tmp}/cympho-production-source.XXXXXX") || return 1
    snapshot_stage=$(run_as_root mktemp -d "$parent/.cympho-source.XXXXXX") || {
        rm -f "$archive_file"
        return 1
    }

    installer_uid=$(id -u)
    installer_gid=$(id -g)

    if ! run_as_root chown "$installer_uid:$installer_gid" "$snapshot_stage" ||
       ! git --no-replace-objects -C "$repo_dir" archive --format=tar --output="$archive_file" "$revision" ||
       ! tar -xf "$archive_file" -C "$snapshot_stage" ||
       ! run_as_root mv -- "$snapshot_stage" "$destination"; then
        rm -f "$archive_file"
        run_as_root rm -rf -- "$snapshot_stage" || true
        return 1
    fi

    rm -f "$archive_file"
    printf '%s\n' "$destination"
}

# Update only the managed revision assignment in an existing environment.
# Secrets and all unrelated lines are copied byte-for-byte, and symlinked
# files are never followed.
reconcile_production_build_revision() {
    local env_file=$1
    local expected_revision=$2
    local current_revision
    local staged_file

    if [ -L "$env_file" ] || [ ! -f "$env_file" ]; then
        install_error "$env_file must be a regular, non-symlink file."
        return 1
    fi

    if [[ ! "$expected_revision" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
        install_error "CYMPHO_BUILD_REVISION must be a 7-64 character hexadecimal revision."
        return 1
    fi

    unset CYMPHO_BUILD_REVISION
    load_production_env_literals "$env_file" || return 1
    current_revision=${CYMPHO_BUILD_REVISION:-}
    expected_revision=${expected_revision,,}

    if [ "$current_revision" = "$expected_revision" ]; then
        return 0
    fi

    staged_file=$(mktemp "${env_file}.cympho-revision.XXXXXX") || return 1
    if ! awk -v revision="$expected_revision" '
        BEGIN { replaced = 0 }
        /^CYMPHO_BUILD_REVISION=/ {
            if (!replaced) {
                print "CYMPHO_BUILD_REVISION=" revision
                replaced = 1
            }
            next
        }
        { print }
        END {
            if (!replaced) print "CYMPHO_BUILD_REVISION=" revision
        }
    ' "$env_file" > "$staged_file"; then
        rm -f "$staged_file"
        return 1
    fi

    chmod --reference="$env_file" "$staged_file" 2>/dev/null || chmod 600 "$staged_file"
    if ! mv -f -- "$staged_file" "$env_file"; then
        rm -f "$staged_file"
        install_error "Could not safely update CYMPHO_BUILD_REVISION in $env_file."
        return 1
    fi
}

reconcile_production_env_key() {
    local env_file=$1
    local key=$2
    local value=$3
    local staged_file

    if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] ||
       [[ ! "$value" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        install_error "Invalid managed production environment key or value."
        return 1
    fi

    staged_file=$(mktemp "${env_file}.cympho-key.XXXXXX") || return 1
    if ! awk -v key="$key" -v value="$value" '
        BEGIN { replaced = 0 }
        index($0, key "=") == 1 {
            if (!replaced) print $0
            replaced = 1
            next
        }
        { print }
        END { if (!replaced) print key "=" value }
    ' "$env_file" > "$staged_file"; then
        rm -f "$staged_file"
        return 1
    fi

    chmod --reference="$env_file" "$staged_file" 2>/dev/null || chmod 600 "$staged_file"
    mv -f -- "$staged_file" "$env_file" || {
        rm -f "$staged_file"
        install_error "Could not safely update $key in $env_file."
        return 1
    }
}

load_production_env_literals() {
    local env_file=$1
    local line
    local key
    local value
    local seen="|"

    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ""|\#*) continue ;;
        esac

        # Match the literal KEY=value grammar consumed by systemd's
        # EnvironmentFile. Shell-only forms such as `export`, quoting, and
        # substitutions are rejected instead of being interpreted differently
        # during installation and service startup.
        if [[ "$line" != *=* ]]; then
            install_error "$env_file contains a non-literal or malformed assignment."
            return 1
        fi

        key=${line%%=*}
        value=${line#*=}

        if [[ ! "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || [ -z "$value" ] ||
           [[ "$value" =~ [[:space:]\\\"\'\`\(\)] ]]; then
            install_error "$env_file contains a non-literal or malformed assignment."
            return 1
        fi

        case "$key" in
            MIX_ENV|PORT|APP_HOST|PREVIEW_HOST|SECRET_KEY_BASE|LIVE_VIEW_SALT|\
            DATABASE_URL|DATABASE_SSL|HTTP_BIND_IP|PREVIEW_TOKEN_MAX_AGE|RELEASE_ENV|\
            AGENT_AUTH_SECRET|ANTHROPIC_API_BASE|ANTHROPIC_API_KEY|ANTHROPIC_BASE_URL|\
            ANTHROPIC_DEFAULT_SONNET_MODEL|ANTHROPIC_MODEL|OPENAI_API_KEY|SENTRY_DSN|\
            AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|AWS_REGION|S3_BUCKET|S3_ENDPOINT|\
            S3_HOST|S3_SCHEME|OTEL_EXPORTER_OTLP_ENDPOINT|OTEL_EXPORTER_OTLP_PROTOCOL|\
            OTEL_EXPORTER_OTLP_TRACES_ENDPOINT|OTEL_EXPORTER_OTLP_TRACES_PROTOCOL|\
            OTEL_SERVICE_NAME|CYMPHO_AGENT_JWT_SECRET|CYMPHO_BOOTSTRAP_SECRET|\
            CYMPHO_BUILD_REVISION|CYMPHO_CLAUDE_COMMAND|CYMPHO_CODEX_KNOWN_HOSTS|\
            CYMPHO_CODEX_MODELS|CYMPHO_CODEX_SSH_AUTH_SOCK|CYMPHO_CURSOR_MODELS|\
            CYMPHO_DASHBOARD_PASSWORD|CYMPHO_DASHBOARD_USER|\
            CYMPHO_DISPATCH_ONLY_ISSUE_ID|CYMPHO_ENCRYPTION_KEY|CYMPHO_FINCH_POOL_SIZE|\
            CYMPHO_FORCE_SSL|CYMPHO_IMPORT_SPOOL_DIR|\
            CYMPHO_LOCAL_AGENT_MEMORY_RESERVE_MB|CYMPHO_MAX_CONCURRENT_AGENTS|\
            CYMPHO_MAX_LOCAL_AGENT_RUNS|CYMPHO_OPENCLAW_MODELS|\
            CYMPHO_ORCHESTRATOR_ENABLED|CYMPHO_RESOURCE_PROFILE|\
            CYMPHO_SCHEDULE_ROUTINE_TRIGGERS|CYMPHO_START_BACKLOG_PLANNER|\
            CYMPHO_START_BOARD_APPROVAL_EXECUTOR|CYMPHO_START_HEALTH_CHECKER|\
            CYMPHO_START_HEARTBEAT_WATCHDOG|CYMPHO_START_OVERSIGHT_PATROL|\
            CYMPHO_START_SCHEDULER|CYMPHO_TRUSTED_PROXY_IPS|CYMPHO_UPLOADS_DIR|\
            CYMPHO_USER_JWT_SECRET) ;;
            *)
                install_error "$env_file contains unsupported key $key."
                return 1
                ;;
        esac

        case "$seen" in
            *"|$key|"*)
                install_error "$env_file contains more than one $key assignment."
                return 1
                ;;
        esac

        seen="${seen}${key}|"
        printf -v "$key" '%s' "$value"
        export "$key"
    done < "$env_file"
}

valid_production_runtime_path() {
    local path=$1
    local unsafe_root

    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] || return 1
    [[ "$path" != "/" && "$path" != *"//"* && "$path" != */.. && "$path" != *"/../"* ]] || return 1

    for unsafe_root in /tmp /var/tmp /run /dev/shm; do
        if [ "$path" = "$unsafe_root" ] || [[ "$path" == "$unsafe_root"/* ]]; then
            return 1
        fi
    done

    if [ -n "${PRODUCTION_SOURCE_STAGE:-}" ] &&
       { [ "$path" = "$PRODUCTION_SOURCE_STAGE" ] ||
         [[ "$path" == "$PRODUCTION_SOURCE_STAGE"/* ]]; }; then
        return 1
    fi

    return 0
}

# Validate and export a preserved production environment without evaluating it.
validate_existing_production_env() {
    local env_file=$1
    local requested_domain=$2
    local requested_preview_domain=$3
    local expected_revision=${4:-}
    local allow_missing_revision=${5:-false}
    local allow_missing_runtime_paths=${6:-false}
    local key

    unset MIX_ENV PORT APP_HOST PREVIEW_HOST SECRET_KEY_BASE LIVE_VIEW_SALT
    unset CYMPHO_ENCRYPTION_KEY CYMPHO_USER_JWT_SECRET CYMPHO_AGENT_JWT_SECRET
    unset CYMPHO_RESOURCE_PROFILE CYMPHO_TRUSTED_PROXY_IPS DATABASE_URL
    unset CYMPHO_BUILD_REVISION CYMPHO_UPLOADS_DIR CYMPHO_IMPORT_SPOOL_DIR

    load_production_env_literals "$env_file" || return 1

    if [ "${MIX_ENV:-}" != "prod" ]; then
        install_error "$env_file must set MIX_ENV=prod."
        return 1
    fi

    if [ -z "${PORT:-}" ]; then
        install_error "$env_file has an empty PORT."
        return 1
    fi

    if [ "$PORT" != "4000" ]; then
        install_error "$env_file must set PORT=4000 for the checked-in service and proxy configuration."
        return 1
    fi

    if [ "${APP_HOST:-}" != "$requested_domain" ]; then
        install_error "The requested app domain does not match APP_HOST in $env_file."
        return 1
    fi

    if [ "${PREVIEW_HOST:-}" != "$requested_preview_domain" ]; then
        install_error "The requested preview domain does not match PREVIEW_HOST in $env_file."
        return 1
    fi

    if [ -z "${CYMPHO_BUILD_REVISION:-}" ] && [ "$allow_missing_revision" = "true" ]; then
        :
    elif [[ ! "${CYMPHO_BUILD_REVISION:-}" =~ ^[0-9a-fA-F]{7,64}$ ]]; then
        install_error "$env_file must set CYMPHO_BUILD_REVISION to a 7-64 character hexadecimal revision."
        return 1
    fi

    if [ -n "$expected_revision" ] &&
       { [[ ! "$expected_revision" =~ ^[0-9a-fA-F]{7,64}$ ]] ||
         [ "${CYMPHO_BUILD_REVISION,,}" != "${expected_revision,,}" ]; }; then
        install_error "$env_file must set CYMPHO_BUILD_REVISION to the current source revision."
        return 1
    fi

    for key in \
        SECRET_KEY_BASE LIVE_VIEW_SALT CYMPHO_ENCRYPTION_KEY \
        CYMPHO_USER_JWT_SECRET CYMPHO_AGENT_JWT_SECRET DATABASE_URL; do
        if [ -z "${!key:-}" ]; then
            install_error "$env_file is missing $key."
            return 1
        fi
    done

    for key in CYMPHO_UPLOADS_DIR CYMPHO_IMPORT_SPOOL_DIR; do
        if [ -z "${!key:-}" ] && [ "$allow_missing_runtime_paths" = "true" ]; then
            continue
        elif ! valid_production_runtime_path "${!key:-}"; then
            install_error "$env_file must set $key to a persistent safe absolute path outside the production source snapshot."
            return 1
        fi
    done

    case "$DATABASE_URL" in
        ecto://*|postgres://*|postgresql://*) ;;
        *)
            install_error "$env_file contains an unsupported DATABASE_URL scheme."
            return 1
            ;;
    esac
}

production_env_requires_database_provisioning() {
    [ "$1" = "new" ]
}

install_staged_production_env() {
    local staged_file=$1
    local env_file=$2

    # A same-filesystem hard link is an atomic create-without-overwrite.
    if ! ln "$staged_file" "$env_file"; then
        install_error "$env_file appeared during installation; it was preserved. Re-run the installer."
    fi
}

env_file_is_staged_file() {
    [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

cleanup_production_env_stage() {
    local env_file=$1
    local staged_file=$2
    local database_provisioned=$3

    if [ -z "$staged_file" ] || [ ! -e "$staged_file" ]; then
        return 0
    fi

    if [ "$database_provisioned" -eq 0 ] && \
        env_file_is_staged_file "$env_file" "$staged_file"; then
        rm -f "$env_file" "$staged_file"
    elif env_file_is_staged_file "$env_file" "$staged_file"; then
        # The database now uses this environment's password; retain .env.
        rm -f "$staged_file"
    else
        echo "Warning: $env_file changed during installation." >&2
        echo "Recovery configuration was retained at $staged_file." >&2
    fi
}

cleanup_production_environment_on_exit() {
    if [ -z "$PRODUCTION_ENV_STAGE" ] || [ ! -e "$PRODUCTION_ENV_STAGE" ]; then
        return 0
    fi

    if [ "$PRODUCTION_ENV_PUBLISHED" -eq 1 ]; then
        if [ "$PRODUCTION_DATABASE_MUTATION_ATTEMPTED" -eq 1 ]; then
            echo "Warning: Database provisioning may have completed." >&2
            echo "The matching $ENV_FILE was preserved; do not delete it or replace its database password." >&2
            echo "Verify the cympho_user role, then re-run the installer." >&2
        fi

        cleanup_production_env_stage \
            "$ENV_FILE" \
            "$PRODUCTION_ENV_STAGE" \
            "$PRODUCTION_DATABASE_MUTATION_ATTEMPTED"
    else
        rm -f "$PRODUCTION_ENV_STAGE"
    fi
}

cleanup_install_on_exit() {
    local status=$?
    local remove_source_stage=0

    cleanup_production_environment_on_exit || true

    if [ "${PRODUCTION_SOURCE_SEALED:-0}" -eq 0 ] ||
       { [ "${PRODUCTION_SOURCE_ACTIVATED:-0}" -eq 0 ] &&
         [ "${PRODUCTION_SOURCE_PUBLISHED:-0}" -eq 0 ]; }; then
        remove_source_stage=1
    fi
    if [ -n "${PRODUCTION_SOURCE_STAGE:-}" ] && [ "$remove_source_stage" -eq 1 ]; then
        run_as_root rm -rf -- "$PRODUCTION_SOURCE_STAGE" || true
    fi

    return "$status"
}

provision_production_database() {
    local env_state=$1
    local machine=$2
    local db_password=$3
    local role_lookup

    if ! production_env_requires_database_provisioning "$env_state"; then
        echo "Preserving the existing production database credentials."
        return 0
    fi

    if [ "$machine" != "Linux" ]; then
        return 0
    fi

    echo "Configuring PostgreSQL user for production..."
    if ! role_lookup=$(run_as_postgres psql -XAtq -v ON_ERROR_STOP=1 \
        -c "SELECT 1 FROM pg_roles WHERE rolname = 'cympho_user'"); then
        install_error "Could not safely inspect PostgreSQL role cympho_user."
        return 1
    fi

    case "$role_lookup" in
        "") ;;
        1)
            install_error \
                "PostgreSQL role cympho_user already exists but .env is missing; refusing to replace its password."
            return 1
            ;;
        *)
            install_error "Could not safely determine whether PostgreSQL role cympho_user exists."
            return 1
            ;;
    esac

    # From this point, a lost client acknowledgement could make the database
    # outcome ambiguous. Retain the matching .env even if psql reports failure.
    PRODUCTION_DATABASE_MUTATION_ATTEMPTED=1

    # Passwords generated by this installer are strictly alphanumeric.
    printf "CREATE USER cympho_user WITH PASSWORD '%s' CREATEDB;\n" "$db_password" | \
        run_as_postgres psql -Xq -v ON_ERROR_STOP=1
}

prepare_production_runtime_directories() {
    local service_user=$1
    local uploads_dir=$2
    local import_spool_dir=$3
    local service_uid
    local service_gid

    if [[ ! "$service_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
       ! valid_production_runtime_path "$uploads_dir" ||
       ! valid_production_runtime_path "$import_spool_dir"; then
        install_error "Production runtime data paths must be persistent safe absolute paths outside the production source snapshot."
        return 1
    fi

    service_uid=$(id -u "$service_user") || return 1
    service_gid=$(id -g "$service_user") || return 1

    prepare_production_runtime_directory "$uploads_dir" "$service_uid" "$service_gid" || return 1
    prepare_production_runtime_directory "$import_spool_dir" "$service_uid" "$service_gid"
}

ensure_production_service_account() {
    local service_user=${1:-cympho}
    local service_group=${2:-cympho}
    local service_uid
    local service_gid
    local operator_uid
    local group_entry
    local group_gid
    local group_members
    local passwd_entries
    local shared_primary_account
    local supplementary_gids
    local group_entries
    local group_alias
    local shared_uid_account

    if [[ ! "$service_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
       [[ ! "$service_group" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
       [ "$service_user" = root ] || [ "$service_group" = root ]; then
        install_error "Production service account must be a dedicated non-root Unix account."
        return 1
    fi

    operator_uid=$(id -u) || return 1
    if service_uid=$(id -u "$service_user" 2>/dev/null); then
        if [ "$service_uid" = 0 ]; then
            install_error "Production service account must not be root."
            return 1
        fi
    else
        run_as_root useradd --system --create-home --shell /usr/sbin/nologin --user-group "$service_user" || return 1
        service_uid=$(id -u "$service_user") || return 1
    fi

    if ! group_entry=$(getent group "$service_group" 2>/dev/null); then
        run_as_root groupadd --system "$service_group" || return 1
        group_entry=$(getent group "$service_group" 2>/dev/null) || return 1
    fi
    group_gid=$(printf '%s\n' "$group_entry" | awk -F: 'NF >= 3 { print $3; exit }')
    group_members=$(printf '%s\n' "$group_entry" | awk -F: 'NF >= 4 { print $4; exit }')
    if [[ ! "$group_gid" =~ ^[0-9]+$ ]] || [ "$group_gid" -eq 0 ]; then
        install_error "Production service group must not be root."
        return 1
    fi
    if [ -n "$group_members" ]; then
        install_error "Production service group must not have named members."
        return 1
    fi
    service_gid=$(id -g "$service_user" 2>/dev/null) || return 1
    if [ "$service_gid" != "$group_gid" ]; then
        install_error "Production service account must use its dedicated primary group."
        return 1
    fi
    passwd_entries=$(getent passwd 2>/dev/null) || {
        install_error "Could not verify production service group membership."
        return 1
    }
    group_entries=$(getent group 2>/dev/null) || {
        install_error "Could not verify production service group aliases."
        return 1
    }
    group_alias=$(printf '%s\n' "$group_entries" | awk -F: \
        -v gid="$group_gid" -v service_group="$service_group" \
        '$3 == gid && $1 != service_group { print $1; exit }')
    if [ -n "$group_alias" ]; then
        install_error "Production service group GID must not have another group alias."
        return 1
    fi
    shared_uid_account=$(printf '%s\n' "$passwd_entries" | awk -F: \
        -v uid="$service_uid" -v service_user="$service_user" \
        '$3 == uid && $1 != service_user { print $1; exit }')
    if [ -n "$shared_uid_account" ]; then
        install_error "Production service account UID must not be shared by another username."
        return 1
    fi
    shared_primary_account=$(printf '%s\n' "$passwd_entries" | awk -F: \
        -v gid="$group_gid" -v service_user="$service_user" \
        '$4 == gid && $1 != service_user { print $1; exit }')
    if [ -n "$shared_primary_account" ]; then
        install_error "Production service group must not be shared by another account."
        return 1
    fi

    supplementary_gids=$(id -G "$service_user" 2>/dev/null) || return 1
    for gid in $supplementary_gids; do
        if [[ ! "$gid" =~ ^[0-9]+$ ]] || [ "$gid" -eq 0 ] || [ "$gid" != "$group_gid" ]; then
            install_error "Production service account must not have supplementary groups."
            return 1
        fi
    done

    if [ "$operator_uid" = "$service_uid" ]; then
        install_error "Installer must not run as the cympho service account."
        return 1
    fi
}

prepare_production_runtime_directory() {
    local path=$1
    local service_uid=$2
    local service_gid=$3
    local canonical
    local owner_match

    case "$path" in
        /var/lib/cympho/data/uploads|/var/lib/cympho/data/import-transfers)
            if run_as_root test -L /var/lib/cympho ||
               run_as_root test -L /var/lib/cympho/data ||
               run_as_root test -L "$path"; then
                install_error "Managed production runtime data paths must not contain symlinks."
                return 1
            fi

            run_as_root install -d -m 0755 -o root -g root \
                /var/lib/cympho /var/lib/cympho/data || return 1
            run_as_root install -d -m 0750 -o "$service_uid" -g "$service_gid" "$path"
            ;;

        *)
            if [ ! -d "$path" ] || [ -L "$path" ]; then
                install_error "Custom production runtime data path $path must already be a non-symlink directory owned by the service user."
                return 1
            fi

            canonical=$(cd -- "$path" && pwd -P) || return 1
            owner_match=$(run_as_root find "$path" -prune -user "$service_uid" -print) || return 1
            if [ "$canonical" != "$path" ] || [ "$owner_match" != "$path" ]; then
                install_error "Custom production runtime data path $path must be canonical and owned by the service user."
                return 1
            fi
            ;;
    esac
}

command_exists() {
    command -v "$1" &> /dev/null
}

# Helper function to run commands as root whether we have sudo or are root
run_as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command_exists sudo; then
        sudo "$@"
    else
        install_error "Need root privileges and sudo is not installed."
    fi
}

run_as_service_user() {
    local service_user=$1
    shift

    if command_exists runuser; then
        run_as_root runuser -u "$service_user" -- "$@"
    elif command_exists sudo; then
        sudo -u "$service_user" "$@"
    else
        install_error "runuser or sudo is required to run production probes as the service user."
        return 1
    fi
}

run_as_postgres() {
    if [ "$(id -u)" -eq 0 ]; then
        if ! command_exists runuser; then
            install_error "runuser is required to execute PostgreSQL commands as root."
            return 1
        fi

        runuser -u postgres -- "$@"
    elif command_exists sudo; then
        sudo -u postgres "$@"
    else
        install_error "Need root privileges and sudo is not installed."
    fi
}

atomic_install_root_owned() {
    local source_file=$1
    local target_file=$2
    local target_dir
    local target_name
    local staged_file

    target_dir=$(dirname "$target_file")
    target_name=$(basename "$target_file")

    if run_as_root test -L "$target_file"; then
        install_error "Refusing to replace symlinked configuration file $target_file."
        return 1
    fi

    staged_file=$(run_as_root mktemp "$target_dir/.${target_name}.tmp.XXXXXX") || return 1

    if ! run_as_root install -m 0644 -o root -g root "$source_file" "$staged_file"; then
        run_as_root rm -f "$staged_file" || true
        return 1
    fi

    if ! run_as_root mv -f -- "$staged_file" "$target_file"; then
        run_as_root rm -f "$staged_file" || true
        return 1
    fi
}

# Publish a bootstrap-only file without replacing a path that appeared after
# the caller's initial existence check. The hard-link operation is an atomic
# create in the target directory and therefore fails if any directory entry
# (including a symlink) already occupies the target path.
atomic_install_root_owned_noreplace() {
    local source_file=$1
    local target_file=$2
    local target_dir
    local target_name
    local staged_file

    target_dir=$(dirname "$target_file")
    target_name=$(basename "$target_file")

    if run_as_root test -e "$target_file" || run_as_root test -L "$target_file"; then
        install_error "Refusing to replace existing configuration file $target_file."
        return 1
    fi

    staged_file=$(run_as_root mktemp "$target_dir/.${target_name}.tmp.XXXXXX") || return 1

    if ! run_as_root install -m 0644 -o root -g root "$source_file" "$staged_file"; then
        run_as_root rm -f "$staged_file" || true
        return 1
    fi

    if ! run_as_root ln "$staged_file" "$target_file"; then
        run_as_root rm -f "$staged_file" || true
        install_error "Refusing to replace existing configuration file $target_file."
        return 1
    fi

    if ! run_as_root rm -f "$staged_file"; then
        install_error "Unable to finalize configuration file $target_file."
        return 1
    fi
}

build_caddy_global_candidate() {
    local existing_file=$1
    local candidate_file=$2
    local fragment_file=$3

    awk -v fragment="$fragment_file" '
        BEGIN {
            begin = "# BEGIN CYMPHO MANAGED IMPORT"
            end = "# END CYMPHO MANAGED IMPORT"
            import_line = "import " fragment
            managed = 0
            pending_blanks = 0
            emitted = 0
        }
        {
            trimmed = $0
            sub(/^[ \t]+/, "", trimmed)
            sub(/[ \t]+$/, "", trimmed)

            if (trimmed == begin) {
                if (managed) exit 43
                managed = 1
                next
            }
            if (managed) {
                if (trimmed == end) managed = 0
                next
            }
            if (trimmed == end) exit 43
            field_count = split(trimmed, fields, /[ \t]+/)
            if (field_count >= 2 && fields[1] == "import" && fields[2] == fragment) next

            if ($0 == "") {
                pending_blanks++
                next
            }

            while (pending_blanks > 0 && emitted) {
                print ""
                pending_blanks--
            }
            pending_blanks = 0
            print $0
            emitted = 1
        }
        END {
            if (managed) exit 42
            if (emitted) print ""
            print begin
            print import_line
            print end
        }
    ' "$existing_file" > "$candidate_file"
}

write_cympho_caddy_fragment() {
    local domain=$1
    local preview_domain=$2
    local target_file=$3

    cat > "$target_file" <<EOF
$domain {
    reverse_proxy 127.0.0.1:4000
}

$preview_domain {
    reverse_proxy 127.0.0.1:4000
}
EOF
}

validate_caddy_candidate_files() {
    local candidate_global=$1
    local candidate_fragment=$2
    local caddyfile=$3
    local fragment_file=$4
    local target_dir
    local staged_fragment
    local staged_global
    local validation_source
    local status=0

    target_dir=$(dirname "$caddyfile")
    validation_source=$(mktemp "${TMPDIR:-/tmp}/cympho-caddy-validation.XXXXXX") || return 1
    staged_fragment=$(run_as_root mktemp "$target_dir/.cympho.fragment.validate.XXXXXX") || {
        rm -f "$validation_source"
        return 1
    }
    staged_global=$(run_as_root mktemp "$target_dir/.Caddyfile.validate.XXXXXX") || {
        run_as_root rm -f "$staged_fragment" || true
        rm -f "$validation_source"
        return 1
    }

    if ! run_as_root install -m 0644 -o root -g root \
            "$candidate_fragment" "$staged_fragment" ||
       ! sed "s|^import $fragment_file$|import $staged_fragment|" \
            "$candidate_global" > "$validation_source" ||
       ! run_as_root install -m 0644 -o root -g root \
            "$validation_source" "$staged_global" ||
       ! run_as_root caddy validate --config "$staged_global" --adapter caddyfile; then
        status=1
    fi

    run_as_root rm -f "$staged_fragment" "$staged_global" || true
    rm -f "$validation_source"
    return "$status"
}

caddy_metadata_valid() {
    local mode uid gid
    [[ "$1" =~ ^([0-7]{3,4})[[:space:]]([0-9]+)[[:space:]]([0-9]+)$ ]] || return 1
    mode=${BASH_REMATCH[1]}
    uid=${BASH_REMATCH[2]}
    gid=${BASH_REMATCH[3]}
    # Caddy configuration is root-managed: root ownership is mandatory and
    # group/world write bits are never preserved from an existing file.
    [ "$uid" -eq 0 ] || return 1
    (( (8#$mode & 8#22) == 0 ))
}

read_caddy_metadata() {
    run_as_root stat -c '%a %u %g' "$1" 2>/dev/null ||
        run_as_root stat -f '%Lp %u %g' "$1"
}

caddy_file_matches() {
    local path=$1
    local expected_file=$2
    local expected_meta=$3
    local actual_meta

    run_as_root test ! -L "$path" && run_as_root test -f "$path" || return 1
    run_as_root cmp -s "$path" "$expected_file" || return 1
    actual_meta=$(read_caddy_metadata "$path") || return 1
    [ "$actual_meta" = "$expected_meta" ]
}

atomic_exchange_caddy_file() {
    local source_file=$1 target_file=$2 expected_file=$3 expected_meta=$4
    local candidate_hash candidate_meta displaced_ok candidate_ok mode uid gid swap_path target_dir

    command_exists python3 || {
        install_error "Atomic Caddy exchange requires Python 3 on Linux."
        return 1
    }
    read -r mode uid gid <<<"$expected_meta"
    target_dir=$(dirname "$target_file")
    swap_path=$(run_as_root mktemp "$target_dir/.cympho-exchange.XXXXXX") || return 1
    run_as_root install -m "$mode" -o "$uid" -g "$gid" "$source_file" "$swap_path" || {
        run_as_root rm -f "$swap_path" || true
        return 1
    }
    candidate_hash=$(run_as_root sha256sum "$source_file" 2>/dev/null | awk '{print $1}') || {
        run_as_root rm -f "$swap_path" || true
        return 1
    }
    candidate_meta=$(read_caddy_metadata "$swap_path") || {
        run_as_root rm -f "$swap_path" || true
        return 1
    }
    caddy_file_matches "$target_file" "$expected_file" "$expected_meta" || {
        run_as_root rm -f "$swap_path" || true
        install_error "$target_file changed before atomic Caddy exchange; preserving operator content."
        return 1
    }
    run_as_root python3 - "$swap_path" "$target_file" <<'PY' || {
import ctypes
import os
import platform
import sys

if platform.system() != "Linux":
    raise SystemExit(1)
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    syscall = getattr(libc, "syscall", None)
    number = {"x86_64": 316, "aarch64": 276}.get(platform.machine())
    if syscall is None or number is None:
        raise SystemExit(1)
    syscall.argtypes = [ctypes.c_long, ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    syscall.restype = ctypes.c_long
    renameat2 = lambda d1, p1, d2, p2, flags: syscall(number, d1, p1, d2, p2, flags)
renameat2.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
renameat2.restype = ctypes.c_int
if renameat2(-100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2) != 0:
    raise SystemExit(1)
PY
        run_as_root rm -f "$swap_path" || true
        install_error "Atomic Caddy exchange is unavailable; refusing non-atomic publication."
        return 1
    }

    displaced_ok=0
    caddy_file_matches "$swap_path" "$expected_file" "$expected_meta" && displaced_ok=1
    candidate_ok=0
    [ "$(run_as_root sha256sum "$target_file" 2>/dev/null | awk '{print $1}')" = "$candidate_hash" ] &&
        [ "$(read_caddy_metadata "$target_file")" = "$candidate_meta" ] && candidate_ok=1
    if [ "$displaced_ok" -eq 1 ] && [ "$candidate_ok" -eq 1 ]; then
        # Keep a same-workdir reference to the published candidate for exact
        # rollback validation; the displaced preimage also exists separately
        # in the immutable snapshot file supplied by the caller.
        if ! run_as_root cp -p "$target_file" "$source_file"; then
            run_as_root rm -f "$swap_path" || true
            return 1
        fi
        if ! run_as_root rm -f "$swap_path"; then
            run_as_root rm -f "$swap_path" || true
            return 1
        fi
        return 0
    fi

    if [ "$candidate_ok" -eq 1 ]; then
        run_as_root python3 - "$swap_path" "$target_file" <<'PY' || true
import ctypes
import os
import platform
import sys
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = getattr(libc, "renameat2", None)
if renameat2 is None:
    syscall = getattr(libc, "syscall", None)
    number = {"x86_64": 316, "aarch64": 276}.get(platform.machine())
    if syscall is not None and number is not None:
        result = syscall(number, -100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2)
        if result != 0:
            raise SystemExit(1)
elif renameat2 is not None:
    renameat2(-100, os.fsencode(sys.argv[1]), -100, os.fsencode(sys.argv[2]), 2)
PY
    fi
    run_as_root rm -f "$swap_path" || true
    install_error "$target_file changed during atomic Caddy exchange; preserving operator content."
    return 1
}

validate_caddy_parent_directory() {
    local target_file=$1
    local parent canonical metadata

    parent=$(dirname -- "$target_file")
    if run_as_root test -L "$parent" || ! run_as_root test -d "$parent"; then
        install_error "Caddy target parent directory must be a canonical directory."
        return 1
    fi
    canonical=$(cd -- "$parent" 2>/dev/null && pwd -P) || return 1
    if [ "$canonical" != "$parent" ]; then
        install_error "Caddy target parent directory must not contain symlinks."
        return 1
    fi
    metadata=$(read_caddy_metadata "$parent") || return 1
    if ! caddy_metadata_valid "$metadata"; then
        install_error "Caddy target parent directory must be root-owned and not group/world writable."
        return 1
    fi
}

atomic_install_caddy_file() {
    local source_file=$1
    local target_file=$2
    local metadata=$3
    local expected_had=${4:-}
    local expected_file=${5:-}
    local expected_meta=${6:-}
    local target_dir target_name staged_file mode uid gid

    caddy_metadata_valid "$metadata" || return 1
    if [ -n "$expected_had" ]; then
        if [ "$expected_had" -eq 1 ]; then
            caddy_file_matches "$target_file" "$expected_file" "$expected_meta" || {
                install_error "$target_file changed during installation; refusing to overwrite it."
                return 1
            }
        elif run_as_root test -e "$target_file" || run_as_root test -L "$target_file"; then
            install_error "$target_file appeared during installation; refusing to overwrite it."
            return 1
        fi
    fi
    read -r mode uid gid <<<"$metadata"
    target_dir=$(dirname "$target_file")
    target_name=$(basename "$target_file")
    run_as_root test ! -L "$target_file" || return 1
    staged_file=$(run_as_root mktemp "$target_dir/.${target_name}.tmp.XXXXXX") || return 1
    if ! run_as_root install -m "$mode" -o "$uid" -g "$gid" "$source_file" "$staged_file"; then
        run_as_root rm -f "$staged_file" || true
        return 1
    fi

    if [ "$expected_had" = 0 ]; then
        if ! run_as_root ln "$staged_file" "$target_file"; then
            run_as_root rm -f "$staged_file" || true
            install_error "Refusing to replace existing configuration file $target_file."
            return 1
        fi
        run_as_root rm -f "$staged_file" || return 1
        return 0
    fi

    if [ "$expected_had" = 1 ] &&
       ! caddy_file_matches "$target_file" "$expected_file" "$expected_meta"; then
        run_as_root rm -f "$staged_file" || true
        install_error "$target_file changed during installation; refusing to overwrite it."
        return 1
    fi

    if ! run_as_root mv -f -- "$staged_file" "$target_file"; then
        run_as_root rm -f "$staged_file" || true
        return 1
    fi
}

restore_caddy_files() {
    local had_global=$1 existing_global=$2 caddyfile=$3 candidate_global=$4 global_meta=$5
    local had_fragment=$6 existing_fragment=$7 fragment_file=$8 candidate_fragment=$9
    local fragment_meta=${10}

    if [ "$had_global" -eq 1 ]; then
        caddy_file_matches "$caddyfile" "$existing_global" "$global_meta" ||
            caddy_file_matches "$caddyfile" "$candidate_global" "$global_meta" || return 1
    elif run_as_root test -e "$caddyfile" || run_as_root test -L "$caddyfile"; then
        caddy_file_matches "$caddyfile" "$candidate_global" "$global_meta" || return 1
    fi
    if [ "$had_fragment" -eq 1 ]; then
        caddy_file_matches "$fragment_file" "$existing_fragment" "$fragment_meta" ||
            caddy_file_matches "$fragment_file" "$candidate_fragment" "$fragment_meta" || return 1
    elif run_as_root test -e "$fragment_file" || run_as_root test -L "$fragment_file"; then
        caddy_file_matches "$fragment_file" "$candidate_fragment" "$fragment_meta" || return 1
    fi

    if [ "$had_fragment" -eq 1 ]; then
        # A publication failure may happen before this file was exchanged.
        # Treat an already-restored preimage as a successful no-op; only swap
        # when the live path still contains the candidate under the same CAS.
        if caddy_file_matches "$fragment_file" "$existing_fragment" "$fragment_meta"; then
            :
        elif caddy_file_matches "$fragment_file" "$candidate_fragment" "$fragment_meta"; then
            atomic_exchange_caddy_file "$existing_fragment" "$fragment_file" \
                "$candidate_fragment" "$fragment_meta" || return 1
        else
            return 1
        fi
    else
        if run_as_root test -e "$fragment_file" || run_as_root test -L "$fragment_file"; then
            caddy_file_matches "$fragment_file" "$candidate_fragment" "$fragment_meta" || return 1
            run_as_root rm -f "$fragment_file" || return 1
        fi
    fi
    if [ "$had_global" -eq 1 ]; then
        if caddy_file_matches "$caddyfile" "$existing_global" "$global_meta"; then
            :
        elif caddy_file_matches "$caddyfile" "$candidate_global" "$global_meta"; then
            atomic_exchange_caddy_file "$existing_global" "$caddyfile" \
                "$candidate_global" "$global_meta"
        else
            return 1
        fi
    else
        if run_as_root test -e "$caddyfile" || run_as_root test -L "$caddyfile"; then
            caddy_file_matches "$caddyfile" "$candidate_global" "$global_meta" || return 1
            run_as_root rm -f "$caddyfile" || return 1
        fi
    fi
}

restore_caddy_enablement() {
    local prior_state=$1
    local current_state

    current_state=$(run_as_root systemctl is-enabled caddy 2>/dev/null || true)
    [ -n "$current_state" ] || current_state=not-found
    case "$prior_state:$current_state" in
        enabled:enabled|disabled:disabled|not-found:not-found) return 0 ;;
        disabled:enabled) run_as_root systemctl disable caddy || return 1 ;;
        *) install_error "Caddy enablement changed unexpectedly; manual recovery is required."; return 1 ;;
    esac

    current_state=$(run_as_root systemctl is-enabled caddy 2>/dev/null || true)
    [ "$current_state" = "$prior_state" ] || {
        install_error "Caddy enablement state could not be restored."
        return 1
    }
}

restore_caddy_activity() {
    local prior_state=$1
    local had_global=$2
    local caddyfile=$3
    local current_state

    case "$prior_state" in
        active)
            [ "$had_global" -eq 1 ] || {
                install_error "Cannot restore active Caddy without its prior global configuration."
                return 1
            }
            run_as_root caddy validate --config "$caddyfile" --adapter caddyfile || return 1
            run_as_root systemctl reload-or-restart caddy || return 1
            ;;
        inactive)
            run_as_root systemctl stop caddy || return 1
            ;;
        *) install_error "Cannot restore unknown Caddy active state."; return 1 ;;
    esac

    current_state=$(run_as_root systemctl is-active caddy 2>/dev/null || true)
    [ "$current_state" = "$prior_state" ] || {
        install_error "Caddy active state could not be restored."
        return 1
    }
}

configure_cympho_caddy() {
    local domain=$1
    local preview_domain=$2
    local caddyfile=${3:-/etc/caddy/Caddyfile}
    local fragment_file=${4:-/etc/caddy/cympho.caddy}
    local work_dir existing_global existing_fragment candidate_global candidate_fragment
    local had_global=0
    local had_fragment=0
    local restored=0
    local global_meta="644 0 0"
    local fragment_meta="644 0 0"
    local caddy_enable_state="not-found"
    local caddy_active_state="inactive"

    if [[ ! "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
       [[ ! "$preview_domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
       [ "$domain" = "$preview_domain" ]; then
        install_error "Caddy app and preview domains must be distinct bare hostnames."
        return 1
    fi
    if [[ ! "$caddyfile" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
       [[ ! "$fragment_file" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        install_error "Caddy configuration paths must be safe absolute paths."
        return 1
    fi
    if run_as_root test -L "$caddyfile" || run_as_root test -L "$fragment_file"; then
        install_error "Refusing to manage symlinked Caddy configuration."
        return 1
    fi
    validate_caddy_parent_directory "$caddyfile" || return 1
    validate_caddy_parent_directory "$fragment_file" || return 1

    caddy_enable_state=$(run_as_root systemctl is-enabled caddy 2>/dev/null || true)
    [ -n "$caddy_enable_state" ] || caddy_enable_state=not-found
    case "$caddy_enable_state" in
        enabled|disabled) ;;
        *) install_error "Caddy unit must already have an enabled or disabled state."; return 1 ;;
    esac
    caddy_active_state=$(run_as_root systemctl is-active caddy 2>/dev/null || true)
    case "$caddy_active_state" in
        active|inactive) ;;
        *) install_error "Caddy active state is not safely restorable."; return 1 ;;
    esac
    if [ "$caddy_enable_state" = not-found ] && [ "$caddy_active_state" = active ]; then
        install_error "Caddy cannot be active while its unit is not found."
        return 1
    fi

    work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cympho-caddy.XXXXXX") || return 1
    existing_global="$work_dir/existing.Caddyfile"
    existing_fragment="$work_dir/existing.cympho.caddy"
    candidate_global="$work_dir/candidate.Caddyfile"
    candidate_fragment="$work_dir/candidate.cympho.caddy"

    if run_as_root test -e "$caddyfile"; then
        run_as_root test -f "$caddyfile" || {
            rm -rf "$work_dir"
            install_error "$caddyfile must be a regular file."
            return 1
        }
        run_as_root cat "$caddyfile" > "$existing_global" || { rm -rf "$work_dir"; return 1; }
        had_global=1
        global_meta=$(read_caddy_metadata "$caddyfile") || { rm -rf "$work_dir"; return 1; }
        caddy_metadata_valid "$global_meta" || {
            rm -rf "$work_dir"
            install_error "$caddyfile must be root-owned and not group/world writable."
            return 1
        }
    else
        : > "$existing_global"
    fi

    if run_as_root test -e "$fragment_file"; then
        run_as_root test -f "$fragment_file" || {
            rm -rf "$work_dir"
            install_error "$fragment_file must be a regular file."
            return 1
        }
        run_as_root cat "$fragment_file" > "$existing_fragment" || { rm -rf "$work_dir"; return 1; }
        had_fragment=1
        fragment_meta=$(read_caddy_metadata "$fragment_file") || { rm -rf "$work_dir"; return 1; }
        caddy_metadata_valid "$fragment_meta" || {
            rm -rf "$work_dir"
            install_error "$fragment_file must be root-owned and not group/world writable."
            return 1
        }
    else
        : > "$existing_fragment"
    fi

    write_cympho_caddy_fragment "$domain" "$preview_domain" "$candidate_fragment"
    if ! build_caddy_global_candidate "$existing_global" "$candidate_global" "$fragment_file"; then
        rm -rf "$work_dir"
        install_error "Existing Caddy managed-import markers are malformed."
        return 1
    fi

    # Validation uses root-owned staging files beside the active Caddyfile, so
    # unrelated relative imports keep the same base directory. Active files are
    # unchanged until this exact candidate has passed.
    if ! validate_caddy_candidate_files \
            "$candidate_global" "$candidate_fragment" "$caddyfile" "$fragment_file"; then
        rm -rf "$work_dir"
        install_error "Caddy rejected the candidate Cympho configuration; active files were preserved."
        return 1
    fi

    if { [ "$had_fragment" -eq 1 ] && ! atomic_exchange_caddy_file \
            "$candidate_fragment" "$fragment_file" "$existing_fragment" "$fragment_meta"; } ||
       { [ "$had_fragment" -eq 0 ] && ! atomic_install_caddy_file \
            "$candidate_fragment" "$fragment_file" "$fragment_meta" 0; } ||
       { [ "$had_global" -eq 1 ] && ! atomic_exchange_caddy_file \
            "$candidate_global" "$caddyfile" "$existing_global" "$global_meta"; } ||
       { [ "$had_global" -eq 0 ] && ! atomic_install_caddy_file \
            "$candidate_global" "$caddyfile" "$global_meta" 0; }; then
        if restore_caddy_files \
            "$had_global" "$existing_global" "$caddyfile" "$candidate_global" "$global_meta" \
            "$had_fragment" "$existing_fragment" "$fragment_file" "$candidate_fragment" \
            "$fragment_meta"; then
            restored=1
        fi
        rm -rf "$work_dir"
        if [ "$restored" -eq 1 ]; then
            install_error "Could not atomically publish the Caddy configuration; previous files were restored."
        else
            install_error "Could not publish or fully restore the Caddy configuration; manual recovery is required."
        fi
        return 1
    fi

    # Revalidate the final paths before touching the running service. This
    # catches existing wildcard imports that may also include the stable
    # fragment name, a condition a differently named staging file cannot model.
    if ! run_as_root caddy validate --config "$caddyfile" --adapter caddyfile; then
        if restore_caddy_files \
            "$had_global" "$existing_global" "$caddyfile" "$candidate_global" "$global_meta" \
            "$had_fragment" "$existing_fragment" "$fragment_file" "$candidate_fragment" \
            "$fragment_meta"; then
            restored=1
        fi
        rm -rf "$work_dir"
        if [ "$restored" -eq 1 ]; then
            install_error "Final-path Caddy validation failed; previous files were restored without reload."
        else
            install_error "Final-path Caddy validation and restoration failed; manual recovery is required."
        fi
        return 1
    fi

    if ! run_as_root systemctl enable caddy ||
       ! run_as_root systemctl reload-or-restart caddy; then
        if restore_caddy_files \
            "$had_global" "$existing_global" "$caddyfile" "$candidate_global" "$global_meta" \
            "$had_fragment" "$existing_fragment" "$fragment_file" "$candidate_fragment" \
            "$fragment_meta"; then
            restored=1
        fi

        if [ "$restored" -eq 1 ]; then
            restore_caddy_activity "$caddy_active_state" "$had_global" "$caddyfile" || restored=0
        fi
        if [ "$restored" -eq 1 ]; then
            restore_caddy_enablement "$caddy_enable_state" || restored=0
        fi
        rm -rf "$work_dir"
        if [ "$restored" -eq 1 ]; then
            install_error "Caddy activation failed; previous files were restored and reload was retried."
        else
            install_error "Caddy activation and file restoration failed; manual recovery is required."
        fi
        return 1
    fi

    rm -rf "$work_dir"
}

validate_canonical_systemd_directory() {
    local label=$1
    local path=$2
    local canonical

    if [[ ! "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
       [[ "$path" == "/" || "$path" == *"//"* || "$path" == *"/../"* || "$path" == */.. ]]; then
        install_error "$label must be a canonical absolute path with safe characters only."
        return 1
    fi

    canonical=$(cd -- "$path" 2>/dev/null && pwd -P) || {
        install_error "$label must be an existing directory."
        return 1
    }

    if [ "$canonical" != "$path" ]; then
        install_error "$label must be canonical (no symlink or dot-segment aliases)."
        return 1
    fi
}

validate_systemd_install_inputs() {
    local app_dir=$1
    local asdf_dir=$2
    local service_user=$3
    local env_file=${4:-$app_dir/.env}
    local env_dir

    validate_canonical_systemd_directory "Application directory" "$app_dir" || return 1
    validate_canonical_systemd_directory "asdf directory" "$asdf_dir" || return 1

    if [[ ! "$env_file" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
        install_error "Environment file must be a safe absolute path."
        return 1
    fi

    env_dir=$(dirname -- "$env_file")
    validate_canonical_systemd_directory "Environment file directory" "$env_dir" || return 1

    if [[ ! "$service_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        install_error "Service user must be a safe Unix account name."
        return 1
    fi
}

install_cympho_systemd_service() {
    local app_dir=$1
    local asdf_dir=$2
    local service_user=$3
    local service_file=$4
    local env_file=${5:-$app_dir/.env}
    local uploads_dir=${6:-${CYMPHO_UPLOADS_DIR:-/var/lib/cympho/data/uploads}}
    local import_spool_dir=${7:-${CYMPHO_IMPORT_SPOOL_DIR:-/var/lib/cympho/data/import-transfers}}
    local candidate

    validate_systemd_install_inputs "$app_dir" "$asdf_dir" "$service_user" "$env_file" || return 1
    if ! valid_production_runtime_path "$uploads_dir" ||
       ! valid_production_runtime_path "$import_spool_dir"; then
        install_error "Systemd writable runtime paths must be persistent safe absolute paths."
        return 1
    fi
    candidate=$(mktemp "${TMPDIR:-/tmp}/cympho-service.XXXXXX") || return 1

    cat > "$candidate" <<EOF
[Unit]
Description=Cympho Phoenix Application
After=network.target postgresql.service caddy.service

[Service]
Type=simple
User=$service_user
WorkingDirectory=$app_dir
Environment="PATH=$asdf_dir/shims:$asdf_dir/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=$env_file
PrivateTmp=true
Group=$service_user
Environment=RELEASE_TMP=/tmp
ExecStart=$app_dir/_build/prod/rel/cympho/bin/cympho start
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ReadWritePaths=$uploads_dir $import_spool_dir

[Install]
WantedBy=multi-user.target
EOF

    if ! atomic_install_root_owned_noreplace "$candidate" "$service_file"; then
        rm -f "$candidate"
        return 1
    fi

    PRODUCTION_SOURCE_PUBLISHED=1
    rm -f "$candidate"
}

write_seed_script() {
    local requested_path=${1:-}
    local seed_script
    local content_file

    if [ -n "$requested_path" ]; then
        if [ -L "$requested_path" ]; then
            install_error "Refusing to replace symlinked seed script $requested_path."
            return 1
        fi
        if [ -e "$requested_path" ]; then
            install_error "Refusing to replace existing seed script $requested_path."
            return 1
        fi
    fi

    content_file=$(mktemp "${TMPDIR:-/tmp}/cympho-seed.XXXXXX") || return 1
    if ! cat > "$content_file" <<'EOF_SEED'
alias Cympho.Repo
alias Cympho.Companies
alias Cympho.Users.User

admin_email = System.fetch_env!("CYMPHO_INSTALL_ADMIN_EMAIL")
admin_name = System.fetch_env!("CYMPHO_INSTALL_ADMIN_NAME")
admin_password = System.fetch_env!("CYMPHO_INSTALL_ADMIN_PASSWORD")
company_name = System.fetch_env!("CYMPHO_INSTALL_COMPANY_NAME")
issue_prefix = System.fetch_env!("CYMPHO_INSTALL_ISSUE_PREFIX")

# Check if the company already exists or create a new autonomous one
company = case Repo.get_by(Companies.Company, name: company_name) do
  nil ->
    {:ok, %{company: company}} = Companies.create_autonomous_company(%{
      name: company_name,
      goal_title: "Initial Company Goal",
      issue_prefix: issue_prefix,
      engineer_count: 1,
      adapter: :claude_code
    })
    company
  c -> c
end

user_attrs = %{
  email: admin_email,
  name: admin_name,
  password: admin_password,
  company_id: company.id
}

# Create or update the admin user, then ensure owner+board membership.
# UserAuth resolves current_company from company_memberships only — users.company_id
# alone is not enough and would bounce the admin to /onboarding after login.
user =
  case Repo.get_by(User, email: admin_email) do
    nil ->
      case %User{}
           |> User.registration_changeset(user_attrs)
           |> Repo.insert() do
        {:ok, user} ->
          IO.puts("Admin user created successfully!")
          user

        {:error, changeset} ->
          IO.puts("Failed to create admin user:")
          IO.inspect(changeset.errors)
          raise "install seed failed to create admin user"
      end

    existing ->
      IO.puts("Admin user with this email already exists.")

      existing
      |> Ecto.Changeset.change(company_id: company.id)
      |> Repo.update!()
  end

membership = Companies.ensure_owner_membership!(user.id, company.id)
IO.puts(
  "Owner membership ensured (role=#{membership.role}, is_board_member=#{membership.is_board_member})."
)
EOF_SEED
    then
        rm -f "$content_file"
        return 1
    fi

    if [ -n "$requested_path" ]; then
        # O_EXCL/noclobber makes the check-and-create operation fail if a
        # symlink or another file appears after the initial inspection.
        if ! (umask 077; set -o noclobber; cat "$content_file" > "$requested_path") 2>/dev/null; then
            rm -f "$content_file"
            install_error "Refusing to replace seed script path $requested_path."
            return 1
        fi
        rm -f "$content_file"
        seed_script=$requested_path
    else
        seed_script=$content_file
    fi

    printf '%s\n' "$seed_script"
}

# Helpers can be sourced by shell regression tests without starting installation.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

require_interactive_terminal

echo "==================================================="
echo "     Welcome to Cympho Installation Script!        "
echo "==================================================="

# 1. Ask for installation type
prompt_install_type

DOMAIN=""
PREVIEW_DOMAIN=""
if [ "$IS_PROD" -eq 1 ]; then
    read -p "Enter your Domain or Subdomain (e.g., cympho.example.com): " DOMAIN

    if [[ ! "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
        echo "Error: Enter a bare hostname such as cympho.example.com (no scheme or path)."
        exit 1
    fi

    read -p "Enter the separate Preview Domain (default: preview.$DOMAIN): " PREVIEW_DOMAIN
    PREVIEW_DOMAIN=${PREVIEW_DOMAIN:-preview.$DOMAIN}

    if [[ ! "$PREVIEW_DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || [ "$PREVIEW_DOMAIN" = "$DOMAIN" ]; then
        echo "Error: Preview Domain must be a different bare hostname from the app Domain."
        exit 1
    fi

    echo "Ensure DNS for both $DOMAIN and $PREVIEW_DOMAIN points to this server before Caddy starts."
fi

echo ""
echo "--- Onboarding Details ---"
read -p "Admin Email: " ADMIN_EMAIL
read -p "Admin Name: " ADMIN_NAME
read -s -p "Admin Password (min 8 chars): " ADMIN_PASSWORD
echo ""
read -p "Company Name: " COMPANY_NAME
read -p "Company Issue Prefix (e.g., CYM): " ISSUE_PREFIX

if [ -z "$ISSUE_PREFIX" ]; then
  ISSUE_PREFIX="CYM"
fi

ISSUE_PREFIX=$(printf '%s' "$ISSUE_PREFIX" | tr '[:lower:]' '[:upper:]')
if [[ ! "$ISSUE_PREFIX" =~ ^[A-Z][A-Z0-9]{1,9}$ ]]; then
    echo "Error: Issue prefix must be 2-10 uppercase letters or numbers and start with a letter."
    exit 1
fi

# 2. Detect OS and Machine architecture
OS="$(uname -s)"
ARCH="$(uname -m)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

echo -e "\nDetected OS: $MACHINE ($ARCH)"

# Refuse managed production reruns before account creation, package installs,
# source/environment staging, Caddy changes, or systemd activation.
if [ "$IS_PROD" -eq 1 ] && [ "$MACHINE" = "Linux" ]; then
    require_fresh_production_bootstrap /etc/systemd/system/cympho.service
fi

# 3. Check Repo
if [ ! -f "mix.exs" ]; then
    echo "Warning: mix.exs not found. You must run this script from inside the Cympho project directory."
    read -p "Enter GitHub repo URL to clone, or press Ctrl+C to abort: " REPO_URL
    if [ ! -z "$REPO_URL" ]; then
        git clone "$REPO_URL" cympho_app
        cd cympho_app
    else
        exit 1
    fi
fi

INSTALL_CHECKOUT_DIR=$(pwd -P)
PRODUCTION_SOURCE_STAGE=""
PRODUCTION_SOURCE_SEALED=0
PRODUCTION_SOURCE_ACTIVATED=0
PRODUCTION_SOURCE_PUBLISHED=0
PRODUCTION_ENV_STAGE=""
PRODUCTION_ENV_PUBLISHED=0
PRODUCTION_DATABASE_MUTATION_ATTEMPTED=0
ENV_FILE=".env"
SERVICE_USER=cympho
SERVICE_GROUP=cympho

trap cleanup_install_on_exit EXIT
trap 'exit 1' HUP INT TERM

if [ "$IS_PROD" -eq 1 ]; then
    BUILD_REVISION=$(production_build_revision "$INSTALL_CHECKOUT_DIR") || exit 1
    export CYMPHO_BUILD_REVISION="$BUILD_REVISION"
fi

if [ "$IS_PROD" -eq 1 ] && [ "$MACHINE" = "Linux" ]; then
    ensure_production_service_account "$SERVICE_USER" "$SERVICE_GROUP"
fi

# 4. Check and install base tools on empty VPS
if [ "$MACHINE" == "Mac" ]; then
    if ! command -v brew &> /dev/null; then
        echo "Homebrew not found. Please install it first: https://brew.sh/"
        exit 1
    fi
    echo "Installing dependencies for Mac via Homebrew..."
    brew install postgresql@14 asdf node || true
    brew services start postgresql@14 || true
    if [ "$IS_PROD" -eq 1 ]; then
        brew install caddy || true
    fi

elif [ "$MACHINE" == "Linux" ]; then
    echo "Installing core dependencies for Ubuntu/Linux..."
    
    # Update and install basic tools
    run_as_root apt-get update -y
    run_as_root apt-get install -y curl git unzip wget python3 software-properties-common apt-transport-https build-essential libssl-dev automake autoconf libncurses5-dev procps
    
    # Install Node.js (needed for assets)
    if ! command -v node &> /dev/null; then
        echo "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | run_as_root bash -
        run_as_root apt-get install -y nodejs
    fi

    # Install PostgreSQL
    if ! command -v psql &> /dev/null; then
        echo "Installing PostgreSQL..."
        run_as_root apt-get install -y postgresql postgresql-contrib
        run_as_root systemctl start postgresql
        run_as_root systemctl enable postgresql
    fi

    # Configure UFW firewall if present
    if command -v ufw &> /dev/null && [ "$IS_PROD" -eq 1 ]; then
        echo "Configuring firewall for web traffic..."
        run_as_root ufw allow 80/tcp
        run_as_root ufw allow 443/tcp
    fi
    
    # Asdf installation if missing
    if [ ! -d "$HOME/.asdf" ]; then
        echo "Installing asdf..."
        git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
        echo -e '\n. $HOME/.asdf/asdf.sh' >> ~/.bashrc
        echo -e '\n. $HOME/.asdf/completions/asdf.bash' >> ~/.bashrc
    fi

    # Install Caddy for reverse proxy and SSL if Production
    if [ "$IS_PROD" -eq 1 ]; then
        if ! command -v caddy &> /dev/null; then
            echo "Installing Caddy..."
            run_as_root apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | run_as_root gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | run_as_root tee /etc/apt/sources.list.d/caddy-stable.list
            run_as_root apt-get update -y
            run_as_root apt-get install -y caddy
        fi
    fi
fi

# Ensure asdf is available in the current shell
if [ -f "$HOME/.asdf/asdf.sh" ]; then
    source "$HOME/.asdf/asdf.sh"
fi

# 5. Install Erlang and Elixir based on .tool-versions
if command -v asdf &> /dev/null; then
    echo "Installing Erlang and Elixir plugins via asdf..."
    asdf plugin add erlang || true
    asdf plugin add elixir || true
    echo "Running asdf install to install required versions..."
    asdf install
else
    echo "WARNING: asdf not found. Please ensure Elixir and Erlang are installed manually."
fi

if [ "$IS_PROD" -eq 1 ]; then
    VERIFIED_BUILD_REVISION=$(production_build_revision "$INSTALL_CHECKOUT_DIR") || exit 1
    if [ "$VERIFIED_BUILD_REVISION" != "$BUILD_REVISION" ]; then
        install_error "Production source revision changed while dependencies were being installed."
        exit 1
    fi

    PRODUCTION_SOURCE_STAGE="/var/lib/cympho/source/${BUILD_REVISION}.$(date +%s).$$"
    stage_production_source_snapshot \
        "$INSTALL_CHECKOUT_DIR" "$BUILD_REVISION" "$PRODUCTION_SOURCE_STAGE" >/dev/null || exit 1
    cd -- "$PRODUCTION_SOURCE_STAGE"
    export MIX_BUILD_PATH="$PRODUCTION_SOURCE_STAGE/_build"
    export MIX_DEPS_PATH="$PRODUCTION_SOURCE_STAGE/deps"
    ENV_FILE="$INSTALL_CHECKOUT_DIR/.env"
fi

# 6. Database and Secrets setup
export MIX_ENV="dev"

if [ "$IS_PROD" -eq 1 ]; then
    export MIX_ENV="prod"
    PROD_ENV_STATE=$(production_env_state "$ENV_FILE")

    if [ "$PROD_ENV_STATE" = "existing" ]; then
        chmod 600 "$ENV_FILE"
        validate_existing_production_env "$ENV_FILE" "$DOMAIN" "$PREVIEW_DOMAIN" "" true true
        reconcile_production_build_revision "$ENV_FILE" "$BUILD_REVISION"
        reconcile_production_env_key \
            "$ENV_FILE" CYMPHO_UPLOADS_DIR /var/lib/cympho/data/uploads
        reconcile_production_env_key \
            "$ENV_FILE" CYMPHO_IMPORT_SPOOL_DIR /var/lib/cympho/data/import-transfers
        validate_existing_production_env "$ENV_FILE" "$DOMAIN" "$PREVIEW_DOMAIN" "$BUILD_REVISION"
        DB_PASS=""
    else
        # Generated values are shell- and URL-safe and are never printed.
        DB_PASS=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 20)
    fi

    if production_env_requires_database_provisioning "$PROD_ENV_STATE"; then
        SECRET_KEY_BASE=$(mix phx.gen.secret)
        CYMPHO_ENCRYPTION_KEY=$(mix phx.gen.secret 32)
        CYMPHO_USER_JWT_SECRET=$(mix phx.gen.secret)
        CYMPHO_AGENT_JWT_SECRET=$(mix phx.gen.secret)
        LIVE_VIEW_SALT=$(mix phx.gen.secret 16)
        PRODUCTION_ENV_STAGE=$(mktemp "${ENV_FILE}.cympho-install.XXXXXX")
        chmod 600 "$PRODUCTION_ENV_STAGE"

        cat <<EOF > "$PRODUCTION_ENV_STAGE"
MIX_ENV=prod
PORT=4000
APP_HOST=$DOMAIN
PREVIEW_HOST=$PREVIEW_DOMAIN
CYMPHO_UPLOADS_DIR=/var/lib/cympho/data/uploads
CYMPHO_IMPORT_SPOOL_DIR=/var/lib/cympho/data/import-transfers
SECRET_KEY_BASE=$SECRET_KEY_BASE
LIVE_VIEW_SALT=$LIVE_VIEW_SALT
CYMPHO_ENCRYPTION_KEY=$CYMPHO_ENCRYPTION_KEY
CYMPHO_USER_JWT_SECRET=$CYMPHO_USER_JWT_SECRET
CYMPHO_AGENT_JWT_SECRET=$CYMPHO_AGENT_JWT_SECRET
CYMPHO_BUILD_REVISION=$BUILD_REVISION
# Safe general-purpose defaults. Change to "low" on a 1–2 GB VPS; measured
# high-throughput hosts can opt into "throughput".
CYMPHO_RESOURCE_PROFILE=balanced
# Caddy is the only process allowed to assert the browser-facing HTTPS scheme.
CYMPHO_TRUSTED_PROXY_IPS=127.0.0.1,::1
DATABASE_URL=ecto://cympho_user:$DB_PASS@localhost/cympho_prod
EOF

        install_staged_production_env "$PRODUCTION_ENV_STAGE" "$ENV_FILE"
        PRODUCTION_ENV_PUBLISHED=1

        if ! provision_production_database "$PROD_ENV_STATE" "$MACHINE" "$DB_PASS"; then
            exit 1
        fi

        if ! env_file_is_staged_file "$ENV_FILE" "$PRODUCTION_ENV_STAGE"; then
            install_error "$ENV_FILE changed while the database was being provisioned."
            exit 1
        fi

        cleanup_production_env_stage "$ENV_FILE" "$PRODUCTION_ENV_STAGE" 1
        PRODUCTION_ENV_STAGE=""
        PRODUCTION_ENV_PUBLISHED=0
    else
        provision_production_database "$PROD_ENV_STATE" "$MACHINE" "$DB_PASS"
    fi

    chmod 600 "$ENV_FILE"

    if [ "$PROD_ENV_STATE" = "new" ]; then
        load_production_env_literals "$ENV_FILE"
    fi

    echo "Preparing production dependencies and secrets..."
    mix local.hex --force
    mix local.rebar --force
    mix deps.get
    mix compile --force

    unset DB_PASS
else
    mix local.hex --force
    mix local.rebar --force
    mix deps.get
fi

# Validate the complete production artifact before any migration or seed side
# effects. Local installs retain the original setup-first behavior.
if [ "$IS_PROD" -eq 1 ]; then
    echo "Building assets for production..."
    mix assets.deploy
    echo "Building immutable production release..."
    mix release --overwrite
    install_release_operator_tools "$PRODUCTION_SOURCE_STAGE" "$BUILD_REVISION"
    validate_production_release_payload "$PRODUCTION_SOURCE_STAGE" "$BUILD_REVISION"
fi

# 7. Setup Project Dependencies and Database
echo "Setting up Mix dependencies and database for $MIX_ENV environment..."
mix setup

# 8. Seed the Admin User and Company
echo "Seeding the admin user and company..."
export CYMPHO_INSTALL_ADMIN_EMAIL="$ADMIN_EMAIL"
export CYMPHO_INSTALL_ADMIN_NAME="$ADMIN_NAME"
export CYMPHO_INSTALL_ADMIN_PASSWORD="$ADMIN_PASSWORD"
export CYMPHO_INSTALL_COMPANY_NAME="$COMPANY_NAME"
export CYMPHO_INSTALL_ISSUE_PREFIX="$ISSUE_PREFIX"

SEED_SCRIPT=$(write_seed_script)
if ! mix run "$SEED_SCRIPT"; then
    rm -f "$SEED_SCRIPT"
    exit 1
fi
rm -f "$SEED_SCRIPT"
unset CYMPHO_INSTALL_ADMIN_EMAIL CYMPHO_INSTALL_ADMIN_NAME CYMPHO_INSTALL_ADMIN_PASSWORD
unset CYMPHO_INSTALL_COMPANY_NAME CYMPHO_INSTALL_ISSUE_PREFIX

# 9. Setup Production Services (Systemd + Caddy)
if [ "$IS_PROD" -eq 1 ] && [ "$MACHINE" == "Linux" ]; then
    # The exact tree used for compilation is made immutable before systemd can
    # execute it. Mutable configuration remains in the original checkout and
    # is referenced explicitly by the unit.
    seal_production_source_snapshot "$PRODUCTION_SOURCE_STAGE" "$SERVICE_GROUP"
    PRODUCTION_SOURCE_SEALED=1

    echo "Setting up Systemd service for Cympho..."
    SERVICE_FILE="/etc/systemd/system/cympho.service"
    APP_DIR=$PRODUCTION_SOURCE_STAGE
    ASDF_DIR=$(cd -- "$HOME/.asdf" && pwd -P)

    prepare_production_runtime_directories \
        "$SERVICE_USER" "$CYMPHO_UPLOADS_DIR" "$CYMPHO_IMPORT_SPOOL_DIR"

    install_cympho_systemd_service \
        "$APP_DIR" "$ASDF_DIR" "$SERVICE_USER" "$SERVICE_FILE" "$ENV_FILE" \
        "$CYMPHO_UPLOADS_DIR" "$CYMPHO_IMPORT_SPOOL_DIR"

    run_as_root systemctl daemon-reload
    run_as_root systemctl enable cympho
    run_as_root systemctl restart cympho

    echo "Verifying exact production revision readiness..."
    readiness_ok=0
    for _ in $(seq 1 30); do
        main_pid_before=$(run_as_root systemctl show -p MainPID --value cympho 2>/dev/null || true)
        if [[ "$main_pid_before" =~ ^[1-9][0-9]*$ ]] &&
           run_as_root systemctl is-active --quiet cympho &&
           run_as_service_user "$SERVICE_USER" env \
           CYMPHOCTL_HEALTH_PORT=4000 \
           CYMPHOCTL_APP_HOST="$DOMAIN" \
           "$APP_DIR/_build/prod/rel/cympho/bin/cymphoctl" readiness --expect-revision "$BUILD_REVISION" \
             >/dev/null 2>&1; then
            sleep 1
            main_pid_after=$(run_as_root systemctl show -p MainPID --value cympho 2>/dev/null || true)
            if [ "$main_pid_after" = "$main_pid_before" ] &&
               run_as_root systemctl is-active --quiet cympho; then
                readiness_ok=1
                break
            fi
        fi
        sleep 1
    done
    if [ "$readiness_ok" -ne 1 ]; then
        install_error "Production release did not become ready at the attested revision."
        exit 1
    fi

    # Only expose the proxy after the bootstrap-only unit is published and the
    # service is locally ready. Earlier failures therefore leave Caddy intact.
    echo "Setting up Caddy reverse proxy for $DOMAIN..."
    configure_cympho_caddy "$DOMAIN" "$PREVIEW_DOMAIN"

    PRODUCTION_SOURCE_ACTIVATED=1

    echo "==================================================="
    echo "  Production Installation Complete!                "
    echo "  Local exact-revision readiness verified on 127.0.0.1:4000."
    echo "  Verify public HTTPS and Caddy separately: https://$DOMAIN/api/health"
    echo "  Runtime previews use: https://$PREVIEW_DOMAIN     "
    echo "  Systemd service 'cympho' is running the server.  "
    echo "==================================================="
else
    echo "==================================================="
    echo "  Local Installation Complete!                     "
    echo "  Start the server with: mix phx.server            "
    echo "==================================================="
fi
