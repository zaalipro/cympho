#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEPLOY="$ROOT/deploy.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cympho-cert-reconcile-test.XXXXXX")"
trap 'rm -rf -- "$TMP_DIR"' EXIT

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }

# --- Static Contract Verification ------------------------------------------
python3 - "$DEPLOY" <<'PY' || exit 1
from pathlib import Path
import sys

deploy = Path(sys.argv[1]).read_text()

def require(cond, msg):
    if not cond:
        print(f"not ok - {msg}", file=sys.stderr)
        raise SystemExit(1)

# Must not destructively revoke or delete certificates
require("certbot delete" not in deploy, "deploy must not delete certificates with certbot delete")
require("certbot revoke" not in deploy, "deploy must not revoke working certificates with certbot revoke")
require("rm -rf /etc/letsencrypt" not in deploy, "deploy must not delete /etc/letsencrypt directory")
require("rm -f /etc/letsencrypt" not in deploy, "deploy must not delete /etc/letsencrypt files")

# Must inspect SANs on the existing certificate
require("openssl x509" in deploy and "subjectAltName" in deploy,
        "deploy must inspect subjectAltName on existing certificate")
require('grep -E -o \'DNS:[^, ]+\'' in deploy or 'grep' in deploy,
        "deploy must parse DNS names from SAN extension")

# Must reconcile certificate with --cert-name when existing cert does not match main-only
require('certbot_args="--cert-name ${DOMAIN}"' in deploy,
        "deploy must set --cert-name ${DOMAIN} when reconciling existing certificate")
require('echo "Certificate already covers ${DOMAIN}."' in deploy,
        "deploy must detect when certificate already covers domain")
require('Existing primary TLS remains intact' in deploy,
        "deploy must preserve existing TLS when certbot fails")
PY

printf 'ok - deploy static certificate reconciliation contract verified\n'

# --- Behavioral Verification -----------------------------------------------

# Generate test certificates using openssl
DOMAIN="cympho.llmotions.com"
CERTBOT_EMAIL="admin@llmotions.com"

MAIN_ONLY_CERT="$TMP_DIR/main_only.crt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP_DIR/main.key" -out "$MAIN_ONLY_CERT" \
    -days 1 -subj "/CN=$DOMAIN" -addext "subjectAltName = DNS:$DOMAIN" 2>/dev/null

LEGACY_SAN_CERT="$TMP_DIR/legacy_san.crt"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP_DIR/legacy.key" -out "$LEGACY_SAN_CERT" \
    -days 1 -subj "/CN=$DOMAIN" -addext "subjectAltName = DNS:$DOMAIN, DNS:preview.$DOMAIN" 2>/dev/null

# Extract the certbot reconciliation snippet from deploy.sh
EXTRACTED_SNIPPET="$TMP_DIR/cert_reconcile_snippet.sh"
python3 - "$DEPLOY" "$EXTRACTED_SNIPPET" <<'PY'
from pathlib import Path
import sys

content = Path(sys.argv[1]).read_text()
start_marker = 'cert=/etc/letsencrypt/live/${DOMAIN}/fullchain.pem'
end_marker = 'WARNING: certbot failed'

start = content.index(start_marker)
# Find the fi closing the certbot block
end = content.index('\nfi\nEOF\n', start) + len('\nfi')

snippet = content[start:end]
# Remove the leading backslashes on variables because in deploy.sh they were in a heredoc
clean_snippet = (
    snippet.replace(r'\$cert', '$cert')
           .replace(r'\$cert_sans', '$cert_sans')
           .replace(r'\$certbot_args', '$certbot_args')
           .replace(r'\$(', '$(')
)
Path(sys.argv[2]).write_text(clean_snippet)
PY

# Helper runner that mocks _sudo, certbot, and openssl
run_cert_test() {
    local cert_file="$1"
    local certbot_mode="$2" # "success" or "fail"
    local log_file="$3"

    bash -c '
        set -euo pipefail
        DOMAIN="'"$DOMAIN"'"
        CERTBOT_EMAIL="'"$CERTBOT_EMAIL"'"
        TEST_CERT="'"$cert_file"'"
        CERTBOT_MODE="'"$certbot_mode"'"
        LOG_FILE="'"$log_file"'"

        _sudo() {
            if [ "$1" = "test" ] && [ "$2" = "-f" ]; then
                [ -f "$TEST_CERT" ]
            elif [ "$1" = "openssl" ]; then
                shift
                # Replace the cert path with the test cert
                args=()
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = "/etc/letsencrypt/live/'"$DOMAIN"'/fullchain.pem" ]; then
                        args+=("$TEST_CERT")
                    else
                        args+=("$1")
                    fi
                    shift
                done
                openssl "${args[@]}"
            elif [ "$1" = "certbot" ]; then
                shift
                printf "CERTBOT_CALLED: %s\n" "$*" >> "$LOG_FILE"
                if [ "$CERTBOT_MODE" = "fail" ]; then
                    return 1
                fi
                return 0
            else
                "$@"
            fi
        }

        # Override cert path variable inside snippet
        source "'"$EXTRACTED_SNIPPET"'"
    '
}

# Test 1: Certificate already covers ONLY main domain
LOG_1="$TMP_DIR/test1.log"
: > "$LOG_1"
output_1=$(run_cert_test "$MAIN_ONLY_CERT" success "$LOG_1" 2>&1)
[ ! -s "$LOG_1" ] || fail "certbot was called when cert already covered main domain only"
case "$output_1" in
    *"Certificate already covers $DOMAIN."*) ;;
    *) fail "did not report certificate already covers domain" ;;
esac
printf 'ok - main-only certificate skips reconciliation\n'

# Test 2: Existing certificate has legacy preview SAN -> reconciles to main-only
LOG_2="$TMP_DIR/test2.log"
: > "$LOG_2"
output_2=$(run_cert_test "$LEGACY_SAN_CERT" success "$LOG_2" 2>&1)
[ -s "$LOG_2" ] || fail "certbot was not called when cert had legacy preview SAN"
certbot_call_2=$(cat "$LOG_2")
case "$certbot_call_2" in
    *"--cert-name $DOMAIN -d $DOMAIN"*) ;;
    *) fail "certbot was not invoked with --cert-name $DOMAIN -d $DOMAIN" ;;
esac
case "$output_2" in
    *"Reconciling certificate to cover only $DOMAIN"*) ;;
    *) fail "did not report reconciling certificate" ;;
esac
case "$output_2" in
    *"Certificate now covers $DOMAIN."*) ;;
    *) fail "did not report certificate now covers domain" ;;
esac
printf 'ok - legacy preview SAN certificate is reconciled to main-only\n'

# Test 3: Reconciliation failure preserves existing certificate without destroy
LOG_3="$TMP_DIR/test3.log"
: > "$LOG_3"
cert_checksum_before=$(cksum "$LEGACY_SAN_CERT")
set +e
output_3=$(run_cert_test "$LEGACY_SAN_CERT" fail "$LOG_3" 2>&1)
status_3=$?
set -e
[ "$status_3" -eq 0 ] || fail "certbot failure caused script to abort unexpectedly"
cert_checksum_after=$(cksum "$LEGACY_SAN_CERT")
[ "$cert_checksum_before" = "$cert_checksum_after" ] || \
    fail "existing certificate was modified or destroyed on certbot failure"
case "$output_3" in
    *"WARNING: certbot failed"*"Existing primary TLS remains intact"*) ;;
    *) fail "did not warn and report primary TLS remains intact on failure" ;;
esac
printf 'ok - certbot failure preserves existing valid certificate\n'

# Test 4: Fresh install (cert does not exist) -> issues new cert for main only
LOG_4="$TMP_DIR/test4.log"
: > "$LOG_4"
output_4=$(run_cert_test "$TMP_DIR/nonexistent.crt" success "$LOG_4" 2>&1)
[ -s "$LOG_4" ] || fail "certbot was not called for fresh install"
certbot_call_4=$(cat "$LOG_4")
case "$certbot_call_4" in
    *"-d $DOMAIN"*) ;;
    *) fail "certbot was not called with -d $DOMAIN on fresh install" ;;
esac
case "$certbot_call_4" in
    *"--cert-name"*) fail "certbot unexpectedly used --cert-name on fresh install" ;;
    *) ;;
esac
printf 'ok - fresh install issues main-only certificate\n'

printf '1..4\n'
