---
name: sync
description: Gated sync from private repo to public mirror. Builds changelog, shows diff, asks for approval.
user_invocable: true
---

# /sync — Push to public mirror

You are syncing the private Pepper repo to the public mirror. Follow these steps exactly. Do not skip steps. Do not improvise.

## Step 1: Preflight

Run these checks. If ANY fail, stop and tell the user.

```bash
# Must be on main
git branch --show-current  # must be "main"

# Must be clean
git status --porcelain  # must be empty

# Public remote must exist
git remote get-url public  # must succeed
```

## Step 2: Find last sync point

```bash
# Get the last sync commit message from public repo
git fetch public main
git log public/main -1 --format='%s'
```

The commit message format is: `<summary>\n\nChanges:\n- bullet\n- bullet`

Extract the date or find the matching private commit to determine what's new.

If this is the first sync (fetch fails), everything is new.

## Step 3: Build changelog

Collect commit messages from private main since the last sync. Only include commits that touch PUBLIC files (not agent infra, prompts, internal docs, etc.).

```bash
# Get commits since last sync that touch public files
git log <last-sync-hash>..HEAD --oneline -- \
  dylib/ tools/ test-app/ docs/PR-STATE-MACHINE.md docs/TROUBLESHOOTING.md \
  Makefile .mcp.json README.md ROADMAP.md CLAUDE.md BUGS.md \
  .env.example .gitignore .swift-format .swiftlint.yml \
  pyrightconfig.json ruff.toml requirements.txt smithery.yaml \
  scripts/setup.sh scripts/demo.sh scripts/pre-commit scripts/gen-coverage.py \
  scripts/real-app-smoke.sh scripts/ci.sh scripts/embed-pepper.sh \
  scripts/deny-guard.sh scripts/build-homebrew-bottle.sh \
  scripts/smoke-tests.json scripts/smoke-ice-cubes.json scripts/wikipedia-smoke.json
```

Summarize into a clean changelog. Strip TASK-NNN prefixes. Group by area if there are many.

## Step 4: Build clean snapshot and show diff

```bash
# Build snapshot excluding private files
STAGING_DIR=$(mktemp -d)
rsync -a --exclude-from=".public-exclude" --exclude='.git' ./ "$STAGING_DIR/"

# Export current public state
PUBLIC_DIR=$(mktemp -d)
git archive public/main | tar -x -C "$PUBLIC_DIR" 2>/dev/null

# Show file-level diff
diff -rq "$PUBLIC_DIR" "$STAGING_DIR" --exclude='.git' | head -60
```

Show the user:
1. Number of files changed
2. The file-level diff (which files added/removed/changed)
3. The proposed commit message (changelog from step 3)

## Step 5: Ask for approval

Present the commit message and ask:

> **Proposed commit message:**
> ```
> <one-line summary>
>
> Changes:
> - bullet 1
> - bullet 2
> ```
>
> **Push to public?** Edit the message or type `y` to push, anything else to abort.

If the user edits the message, use their version. If they say no, stop.

## Step 6: Push

```bash
cd "$STAGING_DIR"
git init -q
git checkout -q -b main
git add -A

# Graft onto public history for linear commits
git fetch <public-repo-url> main:public-parent 2>/dev/null
TREE=$(git write-tree)
PARENT=$(git rev-parse public-parent)
COMMIT=$(git commit-tree "$TREE" -p "$PARENT" -m "<approved message>")
git reset -q "$COMMIT"

git remote add public <public-repo-url>
git push public main --force-with-lease
```

Report success with the public repo URL.

## Step 7: Tag the private repo

After a successful push, tag the private repo so the next sync knows where to start:

```bash
git tag "public-sync/$(date +%Y-%m-%d-%H%M)" HEAD
```

## Rules

- NEVER push without explicit user approval of the commit message
- NEVER include files matched by `.public-exclude`
- ALWAYS show the diff before asking to push
- ALWAYS use `--force-with-lease` (not `--force`)
- If the diff is empty, say "Public is up to date" and stop
- Clean up temp dirs on exit
