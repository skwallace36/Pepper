# Tasks

**Tasks are tracked in [GitHub Projects](https://github.com/users/skwallace36/projects/2).**

Agents use `./scripts/pepper-task next` to claim work. No file editing required.

```bash
# Agent workflow:
./scripts/pepper-task next                    # claim next task (by priority)
./scripts/pepper-task next --area area:ci-cd  # claim from specific area
./scripts/pepper-task list                    # show all open tasks
./scripts/pepper-task list --area area:ci-cd  # show tasks in area
```

## Areas

| Label | Description |
|-------|-------------|
| area:ci-cd | GitHub Actions, health checks, test export |
| area:packaging | README, Homebrew, MCP directories |
| area:device-support | xcframework, Bonjour, device connectivity |
| area:android-port | Platform abstraction, iOS wrappers, handler migration |
| area:system-dialogs | Permission swizzles, dialog detection/dismissal |
| area:generic-mode | Build script fixes, app-specific assumptions |
| area:real-world-testing | Wikipedia, Ice Cubes smoke tests |
| area:new-capabilities | Accessibility audit, touch debugging, layout inspector |
| area:test-coverage | Command testing against PepperTestApp |
| area:ice-cubes | Real-app testing against Ice Cubes |

## Priority Labels

P3 (CI/CD, modularize, system dialogs) → P4 (packaging) → P6 (device) → P7 (android, generic) → P8 (real-world) → P9 (new capabilities)

---

**Routing:** Bugs → GitHub Issues (`gh issue list --label bug`) | Priorities → `ROADMAP.md` | Test results → `test-app/COVERAGE.md` | Research → `docs/RESEARCH.md`
