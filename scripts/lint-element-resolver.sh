#!/usr/bin/env bash
# lint-element-resolver.sh — CI check that handlers use PepperElementResolver
# instead of calling pepper_findElement(id:) directly. Direct calls bypass the
# SwiftUI accessibility fallback and break SwiftUI element lookup (see #410).
set -euo pipefail

HANDLERS_DIR="dylib/commands/handlers"

# pepper_findElement(id:) is only allowed inside bridge/ (where the resolver lives).
# Handlers must use PepperElementResolver.resolve() or .resolveByID() instead.
if grep -rn 'pepper_findElement(id:' "$HANDLERS_DIR" 2>/dev/null; then
    echo ""
    echo "ERROR: Direct pepper_findElement(id:) calls found in handlers."
    echo "Use PepperElementResolver.resolveByID() or .resolve(params:in:) instead."
    echo "See issue #410 for context."
    exit 1
fi

echo "OK: No direct pepper_findElement(id:) calls in handlers."
