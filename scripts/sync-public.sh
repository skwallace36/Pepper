#!/bin/bash
# sync-public.sh — Gated sync from private repo to public mirror.
#
# Creates a clean snapshot of the repo (excluding private files),
# shows you exactly what changed, and waits for confirmation before pushing.
#
# Usage:
#   ./scripts/sync-public.sh              # interactive — review and confirm
#   ./scripts/sync-public.sh --dry-run    # just show what would change
#
# First-time setup:
#   git remote add public git@github.com:skwallace36/Pepper-public.git
#   (or whatever the public repo URL is)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PUBLIC_REMOTE="public"
PUBLIC_BRANCH="main"
EXCLUDE_FILE="$REPO_ROOT/.public-exclude"
STAGING_DIR=$(mktemp -d)

trap 'rm -rf "$STAGING_DIR"' EXIT

# --------------------------------------------------------------------------
# Preflight checks
# --------------------------------------------------------------------------

if ! git remote get-url "$PUBLIC_REMOTE" &>/dev/null; then
    echo "❌ Remote '$PUBLIC_REMOTE' not configured."
    echo "   Run: git remote add $PUBLIC_REMOTE <public-repo-url>"
    exit 1
fi

if [ ! -f "$EXCLUDE_FILE" ]; then
    echo "❌ Exclude file not found: $EXCLUDE_FILE"
    exit 1
fi

# Ensure we're on main and clean
CURRENT_BRANCH=$(git branch --show-current)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "❌ Must be on main branch (currently on '$CURRENT_BRANCH')"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "❌ Working tree is dirty. Commit or stash changes first."
    exit 1
fi

# --------------------------------------------------------------------------
# Build clean snapshot
# --------------------------------------------------------------------------

echo "📦 Building clean snapshot..."

# rsync current tree to staging, excluding private files
rsync -a --exclude-from="$EXCLUDE_FILE" \
    --exclude='.git' \
    "$REPO_ROOT/" "$STAGING_DIR/"

# Count what's included
FILE_COUNT=$(find "$STAGING_DIR" -type f | wc -l | tr -d ' ')
echo "   $FILE_COUNT files in clean snapshot"

# --------------------------------------------------------------------------
# Show what's excluded
# --------------------------------------------------------------------------

echo ""
echo "🔒 Excluded from public (private files):"
diff <(cd "$REPO_ROOT" && git ls-files | sort) \
     <(cd "$STAGING_DIR" && find . -type f | sed 's|^\./||' | sort) \
    | grep '^< ' | sed 's/^< /   /' | head -50

EXCLUDED_COUNT=$(diff <(cd "$REPO_ROOT" && git ls-files | sort) \
     <(cd "$STAGING_DIR" && find . -type f | sed 's|^\./||' | sort) \
    | grep -c '^< ' || true)
echo "   ($EXCLUDED_COUNT files excluded)"

# --------------------------------------------------------------------------
# Compare with last public push
# --------------------------------------------------------------------------

echo ""

# Try to fetch latest public state
if git fetch "$PUBLIC_REMOTE" "$PUBLIC_BRANCH" 2>/dev/null; then
    # Initialize a temp git repo in staging to compute diff
    (
        cd "$STAGING_DIR"
        git init -q
        git add -A
        git commit -q -m "snapshot" --allow-empty
    ) > /dev/null 2>&1

    # Show what changed since last sync
    echo "📊 Changes since last sync:"

    # Export public tree to compare
    PUBLIC_DIR=$(mktemp -d)
    trap 'rm -rf "$STAGING_DIR" "$PUBLIC_DIR"' EXIT
    git archive "$PUBLIC_REMOTE/$PUBLIC_BRANCH" | tar -x -C "$PUBLIC_DIR" 2>/dev/null || true

    # Diff the two trees
    DIFF_OUTPUT=$(diff -rq "$PUBLIC_DIR" "$STAGING_DIR" \
        --exclude='.git' 2>/dev/null | head -50 || true)

    if [ -z "$DIFF_OUTPUT" ]; then
        echo "   No changes — public is up to date."
        exit 0
    fi

    echo "$DIFF_OUTPUT" | while IFS= read -r line; do
        echo "   $line"
    done

    CHANGE_COUNT=$(echo "$DIFF_OUTPUT" | wc -l | tr -d ' ')
    echo "   ($CHANGE_COUNT file changes)"
else
    echo "📊 First sync — all files will be pushed."
fi

# --------------------------------------------------------------------------
# Gate: confirm before pushing
# --------------------------------------------------------------------------

if [ "${1:-}" = "--dry-run" ]; then
    echo ""
    echo "🏁 Dry run complete. No changes pushed."
    exit 0
fi

echo ""
read -p "🚀 Push to $PUBLIC_REMOTE/$PUBLIC_BRANCH? [y/N] " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "Aborted."
    exit 0
fi

# --------------------------------------------------------------------------
# Push clean snapshot as new commit on public
# --------------------------------------------------------------------------

echo ""
echo "Pushing to public..."

# Create orphan commit in staging
(
    cd "$STAGING_DIR"
    rm -rf .git
    git init -q
    git checkout -q -b "$PUBLIC_BRANCH"
    git add -A

    # Try to graft onto existing public history
    if git ls-remote "$REPO_ROOT" "$PUBLIC_REMOTE/$PUBLIC_BRANCH" &>/dev/null 2>&1; then
        # Fetch the public branch to get its HEAD
        git fetch -q "$REPO_ROOT" "refs/remotes/$PUBLIC_REMOTE/$PUBLIC_BRANCH:refs/heads/public-parent" 2>/dev/null || true
        if git rev-parse public-parent &>/dev/null 2>&1; then
            # Create commit with parent for clean linear history
            TREE=$(git write-tree)
            PARENT=$(git rev-parse public-parent)
            COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -m "Sync from private repo $(date +%Y-%m-%d)")
            git reset -q "$COMMIT"
        else
            git commit -q -m "Sync from private repo $(date +%Y-%m-%d)"
        fi
    else
        git commit -q -m "Initial public release"
    fi

    git remote add "$PUBLIC_REMOTE" "$(cd "$REPO_ROOT" && git remote get-url "$PUBLIC_REMOTE")"
    git push "$PUBLIC_REMOTE" "$PUBLIC_BRANCH" --force-with-lease
)

echo ""
echo "✅ Public repo synced."
echo "   Remote: $(git remote get-url "$PUBLIC_REMOTE")"
