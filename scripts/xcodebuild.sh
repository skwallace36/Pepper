#!/bin/bash
# xcodebuild wrapper — injects -derivedDataPath for worktree isolation.
#
# Drop-in replacement for xcodebuild. All args are forwarded.
# Derives a unique DerivedData path from the workspace's parent directory name,
# so worktrees don't clobber each other's build artifacts.
#
# Usage: pepper/scripts/xcodebuild.sh [xcodebuild args...]

set -euo pipefail

ARGS=("$@")
HAS_DERIVED_DATA=false
WORKSPACE_PATH=""
for ((i=0; i<${#ARGS[@]}; i++)); do
    if [[ "${ARGS[$i]}" == "-workspace" ]] && ((i+1 < ${#ARGS[@]})); then
        WORKSPACE_PATH="${ARGS[$((i+1))]}"
    fi
    if [[ "${ARGS[$i]}" == "-derivedDataPath" ]]; then
        HAS_DERIVED_DATA=true
    fi
done

if [[ -n "$WORKSPACE_PATH" ]]; then
    WORKSPACE_DIR="$(cd "$(dirname "$WORKSPACE_PATH")" 2>/dev/null && pwd)"
else
    WORKSPACE_DIR="$PWD"
fi

WORKTREE_NAME="$(basename "$WORKSPACE_DIR")"
DERIVED_DATA="/tmp/DerivedData-${WORKTREE_NAME}"

if $HAS_DERIVED_DATA; then
    exec xcodebuild "$@"
else
    echo "[xcodebuild.sh] Using -derivedDataPath $DERIVED_DATA" >&2
    exec xcodebuild "$@" -derivedDataPath "$DERIVED_DATA"
fi
