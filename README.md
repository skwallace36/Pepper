# Pepper

Runtime control for iOS simulator apps. Dylib injected at launch via `DYLD_INSERT_LIBRARIES` — no source modifications needed.

```bash
make setup         # prereqs, deps, git hooks
make test-deploy   # build test app + inject Pepper
make ping          # verify
```

See `CLAUDE.md` for development docs.

## Troubleshooting

**"Connection refused"** — App not running. `make deploy` to relaunch.

**Build fails** — `xcode-select --install`, then `make clean && make build`.

**"Element not found"** — Use the `look` MCP tool (or `python3 tools/pepper-ctl look` from CLI) to see what's actually on screen.

**"No key window available"** — App needs a moment after launch. Wait 2-3 seconds.
