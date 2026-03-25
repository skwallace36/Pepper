#!/bin/bash
set -euo pipefail

# scripts/pepper-coordinator.sh — pre-provision simulators for multi-agent work
#
# Finds N available simulators, boots them, installs the target app, and
# prints SIMULATOR_ID assignments for each worker. Avoids the reactive
# "deploy → blocked → redirect → install" loop.
#
# Usage:
#   ./scripts/pepper-coordinator.sh                  # provision 2 sims (default)
#   ./scripts/pepper-coordinator.sh --workers 3      # provision 3 sims
#   ./scripts/pepper-coordinator.sh --bundle-id X    # install app X instead of test app
#   ./scripts/pepper-coordinator.sh --json            # output as JSON for scripting
#   ./scripts/pepper-coordinator.sh --cleanup         # release all coordinator claims

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS_DIR="$REPO_ROOT/tools"

NUM_WORKERS=2
BUNDLE_ID="${APP_BUNDLE_ID:-com.pepper.testapp}"
JSON_OUTPUT=false
CLEANUP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --workers|-w) NUM_WORKERS="$2"; shift 2 ;;
        --bundle-id)  BUNDLE_ID="$2"; shift 2 ;;
        --json)       JSON_OUTPUT=true; shift ;;
        --cleanup)    CLEANUP=true; shift ;;
        --help|-h)
            echo "Usage: pepper-coordinator.sh [--workers N] [--bundle-id ID] [--json] [--cleanup]"
            echo ""
            echo "Pre-provision simulators for multi-agent orchestration."
            echo ""
            echo "Options:"
            echo "  --workers N, -w N   Number of sims to provision (default: 2)"
            echo "  --bundle-id ID      App to install (default: \$APP_BUNDLE_ID or test app)"
            echo "  --json              Output results as JSON"
            echo "  --cleanup           Release all coordinator-claimed sessions"
            exit 0
            ;;
        *) shift ;;
    esac
done

if [ "$CLEANUP" = true ]; then
    python3 -c "
import sys, os
sys.path.insert(0, '$TOOLS_DIR')
from pepper_sessions import list_sessions, _remove_session

released = 0
for s in list_sessions():
    if s.get('label', '').startswith('coordinator'):
        _remove_session(s['udid'])
        released += 1
        print(f'Released {s[\"udid\"]}')
print(f'{released} session(s) released.')
"
    exit 0
fi

echo "Provisioning $NUM_WORKERS simulator(s) for bundle $BUNDLE_ID..."

RESULT=$(python3 -c "
import sys, os, json
sys.path.insert(0, '$TOOLS_DIR')
from pepper_sessions import provision_simulators

results = provision_simulators($NUM_WORKERS, '$BUNDLE_ID', '$REPO_ROOT')
print(json.dumps(results))
" 2>&1)

if [ $? -ne 0 ]; then
    echo "ERROR: Provisioning failed: $RESULT" >&2
    exit 1
fi

COUNT=$(echo "$RESULT" | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")

if [ "$COUNT" -eq 0 ]; then
    echo "ERROR: No simulators could be provisioned." >&2
    exit 1
fi

if [ "$JSON_OUTPUT" = true ]; then
    echo "$RESULT"
else
    echo ""
    echo "Provisioned $COUNT simulator(s):"
    echo ""
    echo "$RESULT" | python3 -c "
import sys, json
sims = json.load(sys.stdin)
for i, s in enumerate(sims):
    status = 'app installed' if s['installed'] else 'no app'
    print(f'  Worker {i+1}: SIMULATOR_ID={s[\"udid\"]}  ({status})')
print()
print('Launch workers with:')
for i, s in enumerate(sims):
    label = f'worker-{i+1}'
    print(f'  SIMULATOR_ID={s[\"udid\"]} PEPPER_SESSION_LABEL={label} ./scripts/agent-runner.sh builder')
print()
print('Cleanup: ./scripts/pepper-coordinator.sh --cleanup')
"
fi
