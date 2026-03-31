#!/bin/bash
# Flaky test detection — runs a Pepper command N times and reports consistency.
#
# Usage:
#   ./scripts/flaky-detect.sh <command> [runs] [params_json]
#
# Examples:
#   ./scripts/flaky-detect.sh look 5
#   ./scripts/flaky-detect.sh tap 5 '{"text":"Tap Me"}'
#   ./scripts/flaky-detect.sh wait_for 5 '{"until":{"text":"Hello"},"timeout_ms":3000}'
#
# Exit codes:
#   0 — all runs consistent (all pass or all fail)
#   1 — flaky (mixed pass/fail)
#   2 — usage error or pepper-ctl not found

set -euo pipefail

COMMAND="${1:-}"
RUNS="${2:-5}"
PARAMS="${3:-}"

if [ -z "$COMMAND" ]; then
    echo "Usage: $0 <command> [runs] [params_json]"
    echo ""
    echo "Runs a Pepper command N times and checks for inconsistent results."
    echo "Default: 5 runs."
    exit 2
fi

if ! command -v pepper-ctl &>/dev/null; then
    # Try local path
    PEPPER_CTL="./tools/pepper-ctl"
    if [ ! -x "$PEPPER_CTL" ]; then
        echo "Error: pepper-ctl not found in PATH or ./tools/"
        exit 2
    fi
else
    PEPPER_CTL="pepper-ctl"
fi

PASS=0
FAIL=0
ERRORS=()

echo "Flaky detection: running '$COMMAND' $RUNS times..."
echo ""

for i in $(seq 1 "$RUNS"); do
    if [ -n "$PARAMS" ]; then
        OUTPUT=$("$PEPPER_CTL" raw "{\"cmd\":\"$COMMAND\",\"params\":$PARAMS}" 2>&1) || true
    else
        OUTPUT=$("$PEPPER_CTL" "$COMMAND" 2>&1) || true
    fi

    # Check if response indicates success (status: ok) or error
    if echo "$OUTPUT" | grep -q '"status":\s*"error"'; then
        FAIL=$((FAIL + 1))
        ERROR_MSG=$(echo "$OUTPUT" | grep -oE '"message":\s*"[^"]*"' | head -1)
        ERRORS+=("run $i: FAIL — $ERROR_MSG")
        echo "  run $i/$RUNS: FAIL"
    elif echo "$OUTPUT" | grep -q '"status":\s*"ok"'; then
        PASS=$((PASS + 1))
        echo "  run $i/$RUNS: PASS"
    elif echo "$OUTPUT" | grep -qi 'error\|timeout\|not found\|crash'; then
        FAIL=$((FAIL + 1))
        ERRORS+=("run $i: FAIL — $(echo "$OUTPUT" | head -1)")
        echo "  run $i/$RUNS: FAIL"
    else
        PASS=$((PASS + 1))
        echo "  run $i/$RUNS: PASS (assumed)"
    fi

    # Brief pause between runs to avoid overwhelming the server
    [ "$i" -lt "$RUNS" ] && sleep 0.3
done

echo ""
echo "Results: $PASS/$RUNS passed, $FAIL/$RUNS failed"

if [ "$PASS" -gt 0 ] && [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "⚠ FLAKY — command '$COMMAND' produced inconsistent results ($PASS pass, $FAIL fail)"
    echo ""
    echo "Failure details:"
    for err in "${ERRORS[@]}"; do
        echo "  $err"
    done
    exit 1
elif [ "$FAIL" -eq "$RUNS" ]; then
    echo "All runs failed — this is a consistent failure, not flaky."
    exit 0
else
    echo "All runs passed — command is stable."
    exit 0
fi
