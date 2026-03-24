# Troubleshooting

## `make ping` fails

**No simulator booted.**
Boot a simulator in Xcode or run `open -a Simulator`, then try again.

**App not running with Pepper injected.**
`make ping` connects to the in-process WebSocket server, which only exists when the app was launched via `make launch` or `make deploy`. Running the app from Xcode won't inject Pepper. Run `make deploy` and retry.

**Wrong port.**
The port is derived from `SIMULATOR_ID`. If you have multiple simulators, `make ping` may be targeting the wrong one. Check:

```bash
make help   # shows current SIMULATOR_ID and PORT
```

If `SIMULATOR_ID` is blank, no simulator is booted. If it's wrong, set it explicitly:

```bash
make ping SIMULATOR_ID=<udid>
```

---

## Dylib doesn't inject

**`APP_BUNDLE_ID` not set.**
Without a bundle ID, `make launch` has nothing to launch. Set it in `.env`:

```
APP_BUNDLE_ID=com.example.yourapp
```

**Dylib not built.**
Run `make build` first. The dylib must exist at `build/Pepper.framework/Pepper` before launch.

**App wasn't terminated before relaunch.**
`make launch` terminates the app first, but if something went wrong, kill it manually and relaunch:

```bash
make relaunch
```

**Check the logs.**
Look for injection errors in the simulator log:

```bash
make logs
```

---

## Simulator is stuck or unresponsive

**Restart the simulator.**

```bash
xcrun simctl shutdown <udid>
xcrun simctl boot <udid>
```

Or use Xcode → Device and Simulators → select the sim → restart.

**Reset the simulator** (last resort — clears all installed apps):

```bash
xcrun simctl erase <udid>
```

---

## WebSocket port already in use

Another process (or a previous app instance) is holding the port. Kill the app and relaunch:

```bash
make kill
make launch
```

If that doesn't work, find and kill the process holding the port:

```bash
lsof -ti tcp:<port> | xargs kill -9
```

The port is shown in `make help` under `PORT`.

---

## `.venv` not created

**Python 3 not found.**
`make setup` requires Python 3.10+. Install it with Homebrew:

```bash
brew install python@3.12
```

Then run `make setup` again.

**Manual fix.**
If setup still fails to create the venv, create it directly:

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
```

---

## MCP server not connecting

**Wrong path in MCP config.**
The `command` in your MCP client config must point to `.venv/bin/python3` inside the Pepper repo. Relative paths don't work — use the absolute path.

**`.venv` missing deps.**
Verify the MCP server dependencies are installed:

```bash
.venv/bin/python3 -c "import mcp, websockets; print('ok')"
```

If that fails, reinstall:

```bash
.venv/bin/pip install -r requirements.txt
```

---

## Still stuck?

Run `make setup` — it checks prerequisites and reports what's missing. Most common issues show up there.
