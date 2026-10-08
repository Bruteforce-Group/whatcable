#!/usr/bin/env bash
#
# Unit tests for the format 1 probe code: the shared writer
# (probes/test-kit/probe_json.h) in C, and the snapshot checks
# (snapshot_checks.py) in Python, plus a warnings-as-errors compile of every
# format 1 probe (numbered 50 and up). scripts/ci.sh calls this; nothing else
# compiles probe code outside a full smoke-test build.
#
# Usage: scripts/probe-tests/run.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

clang -Wall -Wextra -Werror -DPJ_FAULT_INJECTION -framework CoreFoundation -framework IOKit \
    -o "$OUT/probe_json_test" "$ROOT/scripts/probe-tests/probe_json_test.c"
"$OUT/probe_json_test"

python3 -m unittest discover -s "$ROOT/scripts/probe-tests" -p 'test_*.py'

shopt -s nullglob
for src in "$ROOT"/probes/test-kit/5[0-9]_*.c; do
    clang -fsyntax-only -Wall -Wextra -Werror -mmacosx-version-min=14.0 "$src"
    echo "compiled clean: $(basename "$src")"
done
