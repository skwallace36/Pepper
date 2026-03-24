#!/bin/bash
# CI check: flag handlers that call pepper_findElement(id:) without a
# PepperElementResolver fallback (SwiftUI elements would be missed).
# See: https://github.com/skwallace36/Pepper/issues/410

set -euo pipefail

HANDLERS_DIR="dylib/commands/handlers"
exit_code=0

# Find handler files that call pepper_findElement(id:)
files_with_direct=$(grep -rl 'pepper_findElement(id:' "$HANDLERS_DIR" || true)

for file in $files_with_direct; do
    # Check if the file also references PepperElementResolver (has a fallback)
    if ! grep -q 'PepperElementResolver' "$file"; then
        echo "ERROR: $file calls pepper_findElement(id:) without PepperElementResolver fallback."
        grep -n 'pepper_findElement(id:' "$file"
        echo ""
        exit_code=1
    fi
done

if [ "$exit_code" -eq 0 ]; then
    echo "OK: All handlers with pepper_findElement(id:) have PepperElementResolver fallback."
fi

exit $exit_code
