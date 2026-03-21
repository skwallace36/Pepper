# scripts/

Build and CI scripts.

## Scripts

### `xcodebuild.sh`
Worktree-aware xcodebuild wrapper. Isolates DerivedData per git worktree so parallel builds don't collide.

### `check-xcodebuild.sh`
Claude Code hook that blocks raw `xcodebuild` invocations. Forces use of `make build` or the wrapper script instead, to ensure consistent build settings.

### `pre-commit`
Git pre-commit hook. Runs build checks, syntax validation, MCP tool verification, and path checks before allowing a commit.
