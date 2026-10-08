#!/usr/bin/env bash
#
# Runs a format 1 probe repeatedly and reports how every run ended. Leave
# devices connected: there is no plug test (Darryl, 2026-10-07). A registry
# that changes mid-walk is written as failure records, so a disturbed run is
# labelled rather than silently wrong. A run passes when it ends with a
# complete footer and the validate check finds nothing.
#
# Usage: scripts/probe-tests/stress.sh <probe-binary> [runs=20] [pause-seconds=5]
set -uo pipefail

PROBE="$1"
RUNS="${2:-20}"
PAUSE="${3:-5}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

passed=0
largest=0
for i in $(seq 1 "$RUNS"); do
    f="$OUT/run$i.jsonl"
    "$PROBE" > "$f"
    status=$?
    size=$(wc -c < "$f" | tr -d ' ')
    [ "$size" -gt "$largest" ] && largest=$size
    last=$(tail -n 1 "$f")
    failures=$(printf '%s' "$last" | sed -n 's/.*"failures":\([0-9]*\).*/\1/p')
    if [ "$status" -gt 128 ]; then
        echo "run $i: killed by signal $((status - 128)) after $size bytes"
    elif python3 "$HERE/snapshot_checks.py" validate "$f" > "$OUT/validate$i.txt"; then
        passed=$((passed + 1))
        echo "run $i: complete, $size bytes, ${failures:-?} failure records"
    else
        echo "run $i: exit $status, $size bytes, problems:"
        grep '^PROBLEM' "$OUT/validate$i.txt" | head -5 | sed 's/^/    /'
    fi
    [ "$i" -lt "$RUNS" ] && sleep "$PAUSE"
done
echo "$passed of $RUNS runs complete and valid; largest output $largest bytes"
[ "$passed" -eq "$RUNS" ]
