# pepper

Pepper is a dylib injected into iOS simulator apps. It gives you runtime control — see every element, tap anything, inspect state, debug rendering — all without screenshots.

For project status and priorities, see `ROADMAP.md`.

## Using Pepper

### MCP Tools (preferred)

If the Pepper MCP server is configured (`.mcp.json`), use native tools directly:

- **`look`** — primary tool. Compact screen summary: all interactive elements with tap commands + visible text. Use `raw=true` for full JSON with coordinates/frames. Use `visual=true` to include a simulator screenshot alongside the structured data for visual validation.
- **`tap`** — tap by text, icon name, heuristic, or point
- **`scroll`** — scroll in a direction
- **`navigate`** — deep link or tab switch
- **`back`** — go back / dismiss
- **`screen`** — current screen name
- **`vars_inspect`** — list/dump/mirror/set ViewModel properties
- **`heap`** — discover live objects (classes, controllers, find singletons)
- **`layers`** — CALayer tree at a point (colors, gradients, shadows)
- **`console`** — capture and read app logs
- **`network`** — monitor HTTP traffic
- **`animations`** — scan active animations or trace movement
- **`deploy`** — terminate + relaunch with dylib injection
- **`simulators`** — list sims with active Pepper connections
- **`raw`** — send any command not covered above

Full command reference: `docs/COMMANDS.md`

### CLI Fallback (`pepper-ctl`)

```bash
P="python3 <PEPPER_DIR>/tools/pepper-ctl"
$P look                              # compact screen summary
$P --json look                       # full raw JSON
$P tap --text "Continue"             # tap by label
$P raw '{"cmd":"heap","params":{"action":"classes","pattern":"Manager"}}'
```

### Rules

- **NEVER screenshot standalone.** Use `look` instead. Use `look visual=true` when visual validation is needed. If `look` doesn't work, fix Pepper — don't fall back to standalone screenshots.
- **`look` first, always.** Before tapping, navigating, or asserting — run `look` to understand what's on screen.

## Build & Deploy

```bash
make build    # Build dylib only
make deploy   # Build + launch with injection
make ping     # Verify control plane
```

Source of truth is `dylib/`. Changes go here. `make build` compiles to `build/Pepper.framework`.

Configuration via `.env`:
```bash
APP_BUNDLE_ID=com.pepper.testapp    # Target app bundle ID
APP_ADAPTER_TYPE=generic            # Adapter type (generic or app-specific)
```

## Project Layout

Each directory has its own doc with details:

```
pepper/
├── CLAUDE.md              # This file
├── ROADMAP.md             # Project status, bugs, what's next
├── Makefile               # Build/deploy
├── .mcp.json              # MCP server config for Claude Code
├── dylib/                 # Dylib Swift source → see dylib/DYLIB.md
├── tools/                 # CLI, MCP server, utilities → see tools/TOOLS.md
├── test-app/              # Integration test app → see test-app/TEST-APP.md
├── scripts/               # Build/CI scripts → see scripts/SCRIPTS.md
├── docs/                  # Reference docs → see docs/DOCS.md
├── skills/                # Claude Code skills (/pepper, /stream)
├── build/                 # gitignored
└── .gitignore
```

## Developing Pepper

### Commit Discipline

Commit early and often. Don't let uncommitted changes pile up across many files — commit at natural boundaries (a completed refactor, a bug fix, a feature addition) rather than batching everything into one giant commit at the end. If you've touched 3+ files and the work is in a coherent state, commit it.

**A commit is a checkpoint, not a finish line.** After committing, step back and evaluate: does the original request fully work? Are there remaining steps, edge cases, or verification needed? Keep working until the task is actually done, not just committed.

### Code Conventions

- **One concern per file** — file names should be self-documenting
- **Swift**: use `extension TypeName` in separate files for large types (stored properties stay on core class)
- **Dylib injection** — no source patches needed. `DYLD_INSERT_LIBRARIES` loads the dylib at launch.
- **Bundle ID**: Set via `APP_BUNDLE_ID` in `.env` file. Required for deploy/iterate.

### Adding a Command

See `dylib/DYLIB.md` for the full guide. Short version:
1. Create handler in `dylib/commands/handlers/`
2. Register in `PepperDispatcher.swift`
3. Add MCP tool in `tools/pepper-mcp`
4. Add entry to `docs/COMMANDS.md` summary table (with category)
5. Add test surface + status entry to `test-app/coverage-status.json`
6. Run `make coverage` to regenerate `test-app/COVERAGE.md`
7. `make build` and test

---

**Routing:** Bugs → `BUGS.md` | Work items → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` (auto-generated) | Research → `docs/RESEARCH.md`
