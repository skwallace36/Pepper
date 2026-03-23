# pepper Makefile
# Runtime control for iOS apps — dylib injection

# Load .env if present
-include .env

# ============================================================
# Configuration
# ============================================================

SIMULATOR_ID  ?= $(shell xcrun simctl list devices booted -j 2>/dev/null | python3 -c "import json,sys; devs=json.load(sys.stdin)['devices']; ids=[d['udid'] for r in devs.values() for d in r if d['state']=='Booted']; print(ids[0] if ids else '')" 2>/dev/null)
BUNDLE_ID     ?= $(APP_BUNDLE_ID)
ADAPTER_TYPE  ?= $(or $(APP_ADAPTER_TYPE),generic)
SKIP_PRIVACY  ?= 0
# Per-simulator port: deterministic hash of SIMULATOR_ID → port in 8770-8869.
PORT          ?= $(shell echo "$(SIMULATOR_ID)" | python3 -c "import sys,hashlib; uid=sys.stdin.read().strip(); print(8770 + int(hashlib.md5(uid.encode()).hexdigest()[:4],16) % 100 if uid else 8765)" 2>/dev/null)

PROJECT_DIR := $(shell pwd)
TOOLS_DIR   := $(PROJECT_DIR)/tools
CONTROL_DIR := $(PROJECT_DIR)/dylib
DYLIB_PATH  := $(PROJECT_DIR)/build/Pepper.framework/Pepper

LOGS_DIR    := $(PROJECT_DIR)/build/logs

.PHONY: help build deploy launch kill relaunch ping check lint lint-py fmt-py smoke typecheck \
        logs clean test-client pepper-ctl test-app coverage coverage-check \
        docs setup ci smoke smoke-ice-cubes \
        agent agent-monitor agent-status agent-trigger agents-install agents-uninstall agent-cleanup agents-start agents-stop agent-analyze groom pr-digest \
        fmt fmt-check \
        wikipedia-setup wikipedia-deploy wikipedia-smoke

# ============================================================
# Help
# ============================================================

## help: Show all available targets
help:
	@echo "pepper — Runtime control for iOS apps (dylib injection)"
	@echo ""
	@echo "Quick start:"
	@echo "  make deploy     Build dylib + inject into running app"
	@echo "  make build      Build the Pepper dylib (fast — seconds)"
	@echo "  make launch     Launch app with Pepper injected"
	@echo "  make ping       Verify control plane is responding"
	@echo ""
	@echo "All targets:"
	@grep -E '^## ' $(MAKEFILE_LIST) | sed 's/^## /  /' | column -t -s ':'
	@echo ""
	@echo "Configuration:"
	@echo "  SIMULATOR_ID  = $(SIMULATOR_ID)"
	@echo "  BUNDLE_ID     = $(BUNDLE_ID)"
	@echo "  PORT          = $(PORT)"
	@echo "  SKIP_PRIVACY  = $(SKIP_PRIVACY)  (set to 1 to skip auto-granting permissions)"

# ============================================================
# Core workflow: build dylib → launch with injection
# ============================================================

## build: Build Pepper.framework dylib
build:
	@bash "$(TOOLS_DIR)/build-dylib.sh"

## xcframework: Build Pepper.xcframework (device + simulator)
xcframework:
	@bash "$(TOOLS_DIR)/build-xcframework.sh"

## launch: Launch app on simulator with Pepper injected
launch:
	@if [ ! -f "$(DYLIB_PATH)" ]; then \
		echo "Pepper.framework not found. Run 'make build' first." >&2; \
		exit 1; \
	fi
	@python3 "$(TOOLS_DIR)/check-sim-available.py" "$(SIMULATOR_ID)" "$(TOOLS_DIR)"
	@echo "Launching $(BUNDLE_ID) on $(SIMULATOR_ID) with Pepper injection..."
	-@xcrun simctl terminate "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>/dev/null
	@open -a Simulator --args -CurrentDeviceUDID "$(SIMULATOR_ID)" 2>/dev/null || true
	@xcrun simctl bootstatus "$(SIMULATOR_ID)" -b 2>/dev/null || sleep 2
	@if [ "$(SKIP_PRIVACY)" != "1" ]; then \
		for perm in photos photos-add camera microphone contacts calendar location-always; do \
			xcrun simctl privacy "$(SIMULATOR_ID)" grant $$perm "$(BUNDLE_ID)" 2>/dev/null || true; \
		done; \
	fi
	@SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(DYLIB_PATH)" \
		SIMCTL_CHILD_PEPPER_PORT="$(PORT)" \
		SIMCTL_CHILD_PEPPER_SIM_UDID="$(SIMULATOR_ID)" \
		SIMCTL_CHILD_PEPPER_ADAPTER="$(ADAPTER_TYPE)" \
		SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS="$${PEPPER_AGENT_TYPE:+1}" \
		xcrun simctl launch "$(SIMULATOR_ID)" "$(BUNDLE_ID)"
	@echo "Launched with injection. Control plane at ws://localhost:$(PORT)"
	@python3 -c "import sys, os, time; sys.path.insert(0, '$(TOOLS_DIR)'); \
from pepper_sessions import quick_port_check, claim_simulator_with_port; \
[time.sleep(0.5) for _ in range(20) if not quick_port_check($(PORT), 0.5)]; \
claim_simulator_with_port('$(SIMULATOR_ID)', '$(BUNDLE_ID)', $(PORT), label='make-deploy') if not os.environ.get('PEPPER_AGENT_TYPE') else None" 2>/dev/null || true

## deploy: Build dylib + launch with injection
deploy: build launch
	@echo ""
	@echo "Deploy complete. Run 'make ping' to verify control plane."

## kill: Terminate the running app
kill:
	@xcrun simctl terminate "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>/dev/null && echo "App terminated." || echo "App not running."

## relaunch: Kill and relaunch with injection
relaunch: kill launch

# ============================================================
# Quality checks
# ============================================================

## lint: Run SwiftLint on dylib sources
lint:
	@if command -v swiftlint >/dev/null 2>&1; then \
		swiftlint lint --strict; \
	else \
		echo "SwiftLint not installed. Run: brew install swiftlint" >&2; \
		exit 1; \
	fi

## lint-py: Run ruff linter on Python code
lint-py:
	@ruff check tools/ scripts/gen-coverage.py

## fmt-py: Format Python code with ruff
fmt-py:
	@ruff format tools/ scripts/gen-coverage.py
	@ruff check --fix tools/ scripts/gen-coverage.py

## check: Run all pre-commit checks (build, syntax, MCP, paths)
check:
	@bash "$(PROJECT_DIR)/scripts/pre-commit"

## fmt: Format Swift files in dylib/ with swift-format
fmt:
	@if ! command -v swift-format >/dev/null 2>&1; then \
		echo "swift-format not found. Install with: brew install swift-format" >&2; \
		exit 1; \
	fi
	@echo "Formatting dylib/ Swift files..."
	@find "$(CONTROL_DIR)" -name '*.swift' -print0 | xargs -0 swift-format format --configuration "$(PROJECT_DIR)/.swift-format" --in-place
	@echo "Done."

## fmt-check: Check Swift formatting in dylib/ (no changes, CI-safe)
fmt-check:
	@if ! command -v swift-format >/dev/null 2>&1; then \
		echo "swift-format not found. Install with: brew install swift-format" >&2; \
		exit 1; \
	fi
	@echo "Checking dylib/ Swift formatting..."
	@find "$(CONTROL_DIR)" -name '*.swift' -print0 | xargs -0 swift-format lint --configuration "$(PROJECT_DIR)/.swift-format" --strict && echo "All files formatted correctly." || (echo "Formatting issues found. Run 'make fmt' to fix." >&2; exit 1)

## typecheck: Run pyright type checker on Python code
typecheck:
	@npx --yes pyright

# ============================================================
# Control plane commands
# ============================================================

## ping: Quick health check — test if control plane is responding
ping:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --port $(PORT) ping

## smoke: Run smoke tests against a running Pepper server
smoke:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --port $(PORT) \
		test-report --file "$(PROJECT_DIR)/scripts/smoke-tests.json" \
		--format json --output "$(PROJECT_DIR)/build/smoke-results.json" \
		--continue-on-error
	@echo ""
	@python3 -c "\
import json, sys; \
data = json.load(open('$(PROJECT_DIR)/build/smoke-results.json')); \
results = data.get('results', data) if isinstance(data, dict) else data; \
passed = sum(1 for r in results if r.get('status') == 'pass'); \
failed = [r for r in results if r.get('status') != 'pass']; \
[print(f'  FAIL: {f[\"name\"]} — {f.get(\"message\", \"unknown\")}') for f in failed]; \
print(f'{passed}/{len(results)} tests passed'); \
sys.exit(1 if failed else 0)"

## logs: Tail simulator system log for the injected app
logs:
	@xcrun simctl spawn "$(SIMULATOR_ID)" log stream \
		--predicate 'subsystem CONTAINS "pepper"' \
		--level debug

# ============================================================
# Tools
# ============================================================

## test-client: Start the interactive Python test client
test-client:
	@python3 "$(TOOLS_DIR)/test-client.py" --port $(PORT)

## pepper-ctl: Show pepper-ctl CLI usage
pepper-ctl:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --help

# ============================================================
# Test App
# ============================================================

TEST_APP_DIR  := $(PROJECT_DIR)/test-app
TEST_APP_BUNDLE := com.pepper.testapp

## test-app: Build and install the test app on the booted simulator
test-app:
	@echo "Building PepperTestApp..."
	@xcodebuild -project "$(TEST_APP_DIR)/PepperTestApp.xcodeproj" \
		-scheme PepperTestApp -sdk iphonesimulator \
		-destination "id=$(SIMULATOR_ID)" \
		-configuration Debug build \
		-quiet 2>&1 | tail -1
	@APP=$$(find ~/Library/Developer/Xcode/DerivedData/PepperTestApp-*/Build/Products/Debug-iphonesimulator -name "PepperTestApp.app" -type d 2>/dev/null | head -1); \
	if [ -z "$$APP" ]; then echo "Build failed — app not found." >&2; exit 1; fi; \
	echo "Installing on $(SIMULATOR_ID)..."; \
	xcrun simctl install "$(SIMULATOR_ID)" "$$APP"; \
	echo "PepperTestApp installed. Run 'make deploy BUNDLE_ID=$(TEST_APP_BUNDLE)' to inject Pepper."

## test-deploy: Build test app + build dylib + launch with Pepper injected
test-deploy: test-app build
	@$(MAKE) launch BUNDLE_ID=$(TEST_APP_BUNDLE)

## ci: Full boot → inject → test → teardown cycle
ci:
	@bash "$(PROJECT_DIR)/scripts/ci.sh" $(CI_ARGS)

## smoke: Run smoke tests against any installed app (e.g. make smoke BUNDLE_ID=com.example.app)
smoke:
	@bash "$(PROJECT_DIR)/scripts/real-app-smoke.sh" --bundle-id "$(BUNDLE_ID)" $(SMOKE_ARGS)

## smoke-ice-cubes: Run smoke tests against Ice Cubes app
smoke-ice-cubes:
	@bash "$(PROJECT_DIR)/scripts/real-app-smoke.sh" \
		--bundle-id "com.thomasricouard.IceCubesApp" \
		--suite "$(PROJECT_DIR)/scripts/smoke-ice-cubes.json" \
		$(SMOKE_ARGS)

# ============================================================
# External App Testing (Wikipedia)
# ============================================================

WIKI_BUNDLE_ID := org.wikimedia.wikipedia

## wikipedia-setup: Clone, build, and install Wikipedia iOS on the simulator
wikipedia-setup:
	@bash "$(PROJECT_DIR)/scripts/setup-wikipedia.sh"

## wikipedia-deploy: Build dylib + launch Wikipedia with Pepper injected
wikipedia-deploy: build
	@$(MAKE) launch BUNDLE_ID=$(WIKI_BUNDLE_ID)

## wikipedia-smoke: Run smoke tests against Wikipedia with Pepper
wikipedia-smoke:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --port $(PORT) \
		test-report --file "$(PROJECT_DIR)/scripts/wikipedia-smoke.json" \
		--continue-on-error

# ============================================================
# Housekeeping
# ============================================================

## coverage: Regenerate test-app/COVERAGE.md from source
coverage:
	@python3 "$(PROJECT_DIR)/scripts/gen-coverage.py"

## coverage-check: Verify COVERAGE.md is in sync with source
coverage-check:
	@python3 "$(PROJECT_DIR)/scripts/gen-coverage.py" --check

## docs: Regenerate all auto-generated docs
docs: coverage

## setup: Install deps, verify env, set up git hooks
setup:
	@bash "$(PROJECT_DIR)/scripts/setup.sh"

# ============================================================
# Agent System
# ============================================================

## agent: Run an agent (e.g. make agent TYPE=bugfix)
agent:
	@./scripts/agent-runner.sh "$(TYPE)"

## agent-monitor: Live tail of agent events
agent-monitor:
	@./scripts/agent-monitor.sh

## agent-status: Replay all agent events
agent-status:
	@./scripts/agent-monitor.sh --replay

## agent-trigger: Fire a trigger event (e.g. make agent-trigger EVENT=bug-filed)
agent-trigger:
	@./scripts/agent-trigger.sh "$(EVENT)"

## agents-install: Install post-merge trigger hook
agents-install:
	@ln -sf ../../scripts/hooks/post-merge-trigger.sh .git/hooks/post-merge
	@ln -sf ../../scripts/hooks/pre-push-rebase.sh .git/hooks/pre-push
	@echo "Installed:"
	@echo "  Post-merge: code changes → trigger tester"
	@echo "  Pre-push: auto-rebase agent branches"
	@echo "  Auto-chain: agent opens PR → verifier launches"

## agents-uninstall: Remove hooks
agents-uninstall:
	@rm -f .git/hooks/post-merge .git/hooks/pre-push
	@echo "Agent hooks uninstalled."

## agent-cleanup: Kill orphaned agent processes, worktrees, and extra sims
agent-cleanup:
	@./scripts/agent-cleanup.sh

## agents-start: Start the heartbeat supervisor (launches + monitors all agents)
agents-start:
	@rm -f .pepper-kill
	@./scripts/agent-heartbeat.sh &
	@echo "Heartbeat started. Agents launching. Monitor: make agent-monitor"

## agents-stop: Stop heartbeat + kill all running agents
agents-stop:
	@touch .pepper-kill
	@if [ -f build/logs/heartbeat.pid ]; then \
		kill -TERM $$(cat build/logs/heartbeat.pid) 2>/dev/null || true; \
		rm -f build/logs/heartbeat.pid; \
	fi
	@pgrep -f 'pepper-agent-' 2>/dev/null | while read pid; do \
		kill -TERM "$$pid" 2>/dev/null || true; \
	done
	@pgrep -f 'agent-runner.sh' 2>/dev/null | while read pid; do \
		kill -TERM "$$pid" 2>/dev/null || true; \
	done
	@rm -f build/logs/.lock-* 2>/dev/null || true
	@echo "All agents stopped."

## agent-analyze: Analyze agent session context usage and re-reads
agent-analyze:
	@./scripts/agent-analyze.sh $(ANALYZE_ARGS)

## groom: Groom the issue backlog (triage, prioritize, decompose)
groom:
	@./scripts/agent-runner.sh groomer

## pr-digest: Show prioritized PR review digest
pr-digest:
	@./scripts/pr-digest.sh

## clean: Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf build/
	@echo "Done."
