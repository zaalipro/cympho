#!/bin/sh
# Assert that the shipped container's PID 1 adopts and reaps an orphan.
#
# Run this through the image's real ENTRYPOINT so the process topology matches
# production:
#
#   docker run --rm -i <image> sh -s < scripts/assert-orphan-reaping.sh
#
# A pass requires observing both re-parenting to PID 1 and removal from /proc.
# Missing or ambiguous observations fail closed rather than treating the
# configured process name alone as behavioral evidence.
set -eu

init_comm="$(cat /proc/1/comm)"
echo "PID 1 = $init_comm"

if [ "$init_comm" != "tini" ]; then
  echo "FAIL: PID 1 is '$init_comm', expected tini" >&2
  exit 1
fi

pidfile="$(mktemp)"
trap 'rm -f "$pidfile"' EXIT

# Read fields after /proc/<pid>/stat's parenthesized command name. In this
# remainder field 1 is state and field 2 is ppid.
stat_field() {
  sed -e 's/^.*) //' "/proc/$1/stat" 2>/dev/null | cut -d' ' -f"$2"
}

# The leader exits immediately. Its grandchild records its pid and remains
# alive long enough for the probe to observe the kernel re-parenting it.
sh -c 'sh -c '\''echo $$ > "$0"; exec sleep 5'\'' "$1" & exit 0' _ "$pidfile"

i=0
while [ ! -s "$pidfile" ]; do
  i=$((i + 1))
  if [ "$i" -gt 100 ]; then
    echo "FAIL: grandchild never reported its pid; the probe proved nothing" >&2
    exit 1
  fi
  sleep 0.05
done
gpid="$(cat "$pidfile")"

i=0
while :; do
  ppid="$(stat_field "$gpid" 2)"

  if [ "$ppid" = "1" ]; then
    break
  fi

  if [ -z "$ppid" ]; then
    echo "FAIL: grandchild pid $gpid vanished before adoption was observed; the probe proved nothing" >&2
    exit 1
  fi

  i=$((i + 1))
  if [ "$i" -gt 20 ]; then
    echo "FAIL: grandchild still has ppid=$ppid; adoption by PID 1 was not observed; the probe proved nothing" >&2
    exit 1
  fi
  sleep 0.05
done
echo "orphaned grandchild pid=$gpid reparented to ppid=$ppid"

# The child exits after about five seconds. If PID 1 does not wait for it, its
# /proc entry remains as a zombie. A successful observation is disappearance,
# not merely a non-zombie snapshot that may have been taken too early.
i=0
while [ "$i" -lt 100 ]; do
  if [ ! -e "/proc/$gpid" ]; then
    echo "PASS: PID 1 reaped orphaned pid $gpid"
    exit 0
  fi

  i=$((i + 1))
  sleep 0.1
done

state="$(stat_field "$gpid" 1)"
echo "FAIL: pid $gpid remains after 100 polls (state=$state); PID 1 ('$init_comm') did not reap it" >&2
exit 1
