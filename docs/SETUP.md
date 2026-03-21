# Setup

Run `make setup` — it checks everything and gets you ready.

For manual setup or details, see `CLAUDE.md` at project root.

## Troubleshooting

**"Connection refused"**
- Is the app running? `make deploy`
- Check for a stale process: `lsof -i -sTCP:LISTEN | grep pepper`
- Kill and relaunch: `make kill && make launch`

**Build fails**
- Xcode CLI tools: `xcode-select --install`
- Clean build: `make clean && make build`

**"Element not found"**
- Run `look` to see what's on screen
- Check current screen: `screen`

**"No key window available"**
- App needs a moment after launch. Wait 2-3 seconds, retry.

---

**Routing:** Bugs → `../BUGS.md` | Work items → `../ROADMAP.md` | Test coverage → `../test-app/COVERAGE.md` | Research → `RESEARCH.md`
