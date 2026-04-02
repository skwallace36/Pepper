#!/bin/bash
# Deterministic release script.
# Usage: scripts/release.sh <patch|minor|major>
#
# Steps:
#   1. Validate: on main, clean tree, not already tagged
#   2. Bump version in pyproject.toml + pepper_ios/__init__.py
#   3. Create a PR for the version bump, merge it
#   4. Tag main and push the tag (triggers mirror → release → PyPI via CI)
#
# The CI pipeline handles everything after the tag push:
#   mirror-code.yml  →  rewrites + pushes to public repo (including tag)
#   release.yml      →  builds dylib, creates GitHub releases, publishes PyPI

set -euo pipefail

BUMP="${1:-}"
if [[ ! "$BUMP" =~ ^(patch|minor|major)$ ]]; then
    echo "Usage: scripts/release.sh <patch|minor|major>"
    exit 1
fi

# --- Guards ---
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "ERROR: must be on main (currently on $BRANCH)"
    exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree is dirty — commit or stash first"
    exit 1
fi

git fetch origin main --quiet
LOCAL=$(git rev-parse HEAD)
REMOTE=$(git rev-parse origin/main)
if [ "$LOCAL" != "$REMOTE" ]; then
    echo "ERROR: local main is not up to date with origin — pull first"
    exit 1
fi

# --- Read current version ---
CURRENT=$(python3 -c "
import re
with open('pyproject.toml') as f:
    m = re.search(r'version = \"(.+?)\"', f.read())
    print(m.group(1))
")
echo "Current version: $CURRENT"

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

case "$BUMP" in
    major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
    minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
    patch) PATCH=$((PATCH + 1)) ;;
esac

NEW="$MAJOR.$MINOR.$PATCH"
TAG="v$NEW"

if git tag -l "$TAG" | grep -q .; then
    echo "ERROR: tag $TAG already exists"
    exit 1
fi

echo "Bumping: $CURRENT → $NEW ($BUMP)"

# --- Branch, bump, PR, merge ---
RELEASE_BRANCH="release/$TAG"
git checkout -b "$RELEASE_BRANCH"

sed -i '' "s/version = \"$CURRENT\"/version = \"$NEW\"/" pyproject.toml
sed -i '' "s/__version__ = \"$CURRENT\"/__version__ = \"$NEW\"/" pepper_ios/__init__.py

# Verify
PKG_VER=$(python3 -c "from pepper_ios import __version__; print(__version__)")
if [ "$PKG_VER" != "$NEW" ]; then
    echo "ERROR: version mismatch after bump — pyproject says $NEW but __init__ says $PKG_VER"
    git checkout main
    git branch -D "$RELEASE_BRANCH"
    exit 1
fi

git add pyproject.toml pepper_ios/__init__.py
git commit -m "Release $TAG"
git push -u origin "$RELEASE_BRANCH"
gh pr create --title "Release $TAG" --body "Version bump: $CURRENT → $NEW"
gh pr merge --squash --delete-branch

# --- Tag and push ---
git checkout main
git pull origin main --quiet
git tag "$TAG"
git push origin "$TAG"

echo ""
echo "=== Released $TAG ==="
echo "CI will now run:"
echo "  1. Mirror → public repo (includes tag)"
echo "  2. Release → GitHub releases + PyPI"
echo ""
echo "Monitor: gh run list --workflow=release.yml --limit=1"
