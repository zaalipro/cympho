#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="${ROOT}/bin/cymphoctl"
VALIDATOR="${ROOT}/bin/cympho-health-validator"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

assert_source() {
  local needle="$1"
  local message="$2"
  grep -Fq -- "$needle" "$CLI" || fail "$message"
}

[[ -x "$CLI" ]] || fail "bin/cymphoctl must be executable"
[[ -x "$VALIDATOR" ]] || fail "bin/cympho-health-validator must be executable"
bash -n "$CLI" || fail "bin/cymphoctl must pass bash syntax validation"
python3 - "$VALIDATOR" <<'PY' || fail "the JSON validator must pass Python syntax validation"
import ast
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    ast.parse(source.read(), filename=sys.argv[1])
PY

if grep -Eq '(^|[^[:alnum:]_])(eval|sudo)([^[:alnum:]_]|$)' "$CLI"; then
  fail "cymphoctl must not evaluate text or acquire privileges"
fi

assert_source 'http://127.0.0.1:${HEALTH_PORT}/api/health' \
  "readiness must stay on loopback"
assert_source "--max-redirs 0" "readiness must reject redirects"
assert_source "--connect-timeout" "readiness must bound connect time"
assert_source "--max-time" "readiness must bound total time"
assert_source "--max-filesize" "readiness must bound retained response bytes"
assert_source "--disable" "readiness must ignore user curl configuration"
assert_source "--noproxy '*'" "readiness must not send loopback through a proxy"
assert_source '%{content_type}' "readiness must validate the HTTP media type"
assert_source "--no-pager" "service commands must never invoke a pager"
assert_source "exec env SYSTEMD_PAGER=cat PAGER=cat journalctl" \
  "logs must directly replace the CLI with journalctl"

printf 'ok - cymphoctl has the static read-only and bounded-command contract\n'
printf '1..1\n'
