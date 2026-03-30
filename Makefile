# pepper Makefile
# Runtime control for iOS apps — dylib injection

# Load .env if present; .env.local overrides (machine-local, gitignored)
-include .env
-include .env.local

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

TEST_APP_DIR  := $(PROJECT_DIR)/test-app
TEST_APP_BUNDLE := com.pepper.testapp

WIKI_BUNDLE_ID := org.wikimedia.wikipedia

.PHONY: help build build-device xcframework deploy launch kill relaunch ping check lint lint-py fmt-py smoke typecheck \
        logs clean test-client pepper-ctl test-app demo coverage coverage-check commands commands-check unit-test py-test \
        docs setup ci smoke smoke-ice-cubes \
        agent agent-monitor agent-status agent-trigger agents-install agents-uninstall agent-cleanup agents-start agents-stop agent-analyze groom pr-digest coordinator \
        fmt fmt-check ci-agents-install ci-agents-check \
        wikipedia-setup wikipedia-deploy wikipedia-smoke \
        dashboard

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
# Setup
# ============================================================

## setup: Install deps, verify env, set up git hooks
setup:
	@bash "$(PROJECT_DIR)/scripts/setup.sh"

# ============================================================
# Build
# ============================================================

## build: Build Pepper.framework dylib
build:
	@bash "$(TOOLS_DIR)/build-dylib.sh"

## xcframework: Build Pepper.xcframework (device + simulator)
xcframework:
	@bash "$(TOOLS_DIR)/build-xcframework.sh"

## build-device: Build Pepper.framework for physical iOS devices (arm64)
build-device:
	@bash "$(TOOLS_DIR)/build-dylib.sh" --device

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
	@LAUNCH_OUTPUT=$$(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(DYLIB_PATH)" \
		SIMCTL_CHILD_PEPPER_PORT="$(PORT)" \
		SIMCTL_CHILD_PEPPER_SIM_UDID="$(SIMULATOR_ID)" \
		SIMCTL_CHILD_PEPPER_ADAPTER="$(ADAPTER_TYPE)" \
		SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS="$${PEPPER_AGENT_TYPE:+1}" \
		xcrun simctl launch "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>&1) || { \
		if echo "$$LAUNCH_OUTPUT" | grep -qi "domain.*error\|unable to lookup.*application\|not found"; then \
			echo "App not installed on $(SIMULATOR_ID). Auto-installing..."; \
			$(MAKE) test-app SIMULATOR_ID="$(SIMULATOR_ID)" && \
			LAUNCH_OUTPUT=$$(SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(DYLIB_PATH)" \
				SIMCTL_CHILD_PEPPER_PORT="$(PORT)" \
				SIMCTL_CHILD_PEPPER_SIM_UDID="$(SIMULATOR_ID)" \
				SIMCTL_CHILD_PEPPER_ADAPTER="$(ADAPTER_TYPE)" \
				SIMCTL_CHILD_PEPPER_SKIP_PERMISSIONS="$${PEPPER_AGENT_TYPE:+1}" \
				xcrun simctl launch "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>&1) || { \
				echo "$$LAUNCH_OUTPUT" >&2; exit 1; \
			}; \
		else \
			echo "$$LAUNCH_OUTPUT" >&2; exit 1; \
		fi; \
	}; echo "$$LAUNCH_OUTPUT"
	@echo "Launched with injection. Control plane at ws://localhost:$(PORT)"
	@python3 -c "import sys, os, time; sys.path.insert(0, '$(TOOLS_DIR)'); \
from pepper_sessions import quick_port_check, claim_simulator_with_port; \
[time.sleep(0.5) for _ in range(20) if not quick_port_check($(PORT), 0.5)]; \
claim_simulator_with_port('$(SIMULATOR_ID)', '$(BUNDLE_ID)', $(PORT), label='make-deploy') if not os.environ.get('PEPPER_AGENT_TYPE') else None" 2>/dev/null || true

## kill: Terminate the running app
kill:
	@xcrun simctl terminate "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>/dev/null && echo "App terminated." || echo "App not running."

## relaunch: Kill and relaunch with injection
relaunch: kill launch

# ============================================================
# Deploy
# ============================================================

## deploy: Build dylib + launch with injection
deploy: build launch
	@echo ""
	@echo "Deploy complete. Run 'make ping' to verify control plane."

## test-deploy: Build test app + build dylib + launch with Pepper injected
test-deploy: test-app build
	@$(MAKE) launch BUNDLE_ID=$(TEST_APP_BUNDLE)

# ============================================================
# Quality
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
	@ruff check pepper_ios/ tools/ scripts/gen-coverage.py scripts/gen-pepper-commands.py

## fmt-py: Format Python code with ruff
fmt-py:
	@ruff format pepper_ios/ tools/ scripts/gen-coverage.py scripts/gen-pepper-commands.py
	@ruff check --fix pepper_ios/ tools/ scripts/gen-coverage.py scripts/gen-pepper-commands.py

## check-tools: Verify every MCP tool has a matching dylib handler
check-tools:
	@bash "$(PROJECT_DIR)/scripts/check-tool-coverage.sh"

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

## ci: Full boot → inject → test → teardown cycle
ci:
	@bash "$(PROJECT_DIR)/scripts/ci.sh" $(CI_ARGS)

# ============================================================
# Test
# ============================================================

## ping: Quick health check — test if control plane is responding
ping:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --port $(PORT) ping

## smoke: Run smoke tests against any installed app (e.g. make smoke BUNDLE_ID=com.example.app)
smoke:
	@bash "$(PROJECT_DIR)/scripts/real-app-smoke.sh" --bundle-id "$(BUNDLE_ID)" $(SMOKE_ARGS)

## smoke-ice-cubes: Run smoke tests against Ice Cubes app
smoke-ice-cubes:
	@bash "$(PROJECT_DIR)/scripts/real-app-smoke.sh" \
		--bundle-id "com.thomasricouard.IceCubesApp" \
		--suite "$(PROJECT_DIR)/scripts/smoke-ice-cubes.json" \
		$(SMOKE_ARGS)

## unit-test: Run Swift unit tests (Foundation-level, no simulator required)
unit-test:
	@swift test --package-path "$(PROJECT_DIR)/tests/unit"

## py-test: Run Python unit tests for the MCP tool layer
py-test:
	@python3 -m pytest tools/tests/ -v

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

## demo: Run interactive demo walkthrough (build + inject + observe + interact)
demo:
	@bash "$(PROJECT_DIR)/scripts/demo.sh" $(DEMO_ARGS)

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
# Agent (private — stripped from public mirror)
# ============================================================

## agent: Run an agent (e.g. make agent TYPE=bugfix)
agent:
	@./scripts/agent-runner.sh "$(TYPE)"

## dashboard: TUI dashboard for agent monitoring (requires textual)
dashboard:
	@python3 scripts/agent-dashboard.py

## agent-monitor: Live tail of agent events (bash fallback)
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
	@ln -sf ../../scripts/hooks/post-checkout-guard.sh .git/hooks/post-checkout
	@echo "Installed:"
	@echo "  Post-merge: code changes → trigger tester"
	@echo "  Pre-push: auto-rebase agent branches"
	@echo "  Post-checkout: prevent agents from leaving main on primary worktree"
	@echo "  Auto-chain: agent opens PR → verifier launches"

## agents-uninstall: Remove hooks
agents-uninstall:
	@rm -f .git/hooks/post-merge .git/hooks/pre-push .git/hooks/post-checkout
	@echo "Agent hooks uninstalled."

## coordinator: Pre-provision sims for multi-agent work (e.g. make coordinator WORKERS=3)
coordinator:
	@./scripts/pepper-coordinator.sh --workers "$(or $(WORKERS),2)"

## agent-cleanup: Kill orphaned agent processes, worktrees, and extra sims
agent-cleanup:
	@./scripts/agent-cleanup.sh

## agents-start: Start the heartbeat supervisor (launches + monitors all agents)
agents-start:
	@nohup ./scripts/agent-heartbeat.sh >> build/logs/heartbeat.log 2>&1 & sleep 1; \
	if [ -f build/logs/heartbeat.pid ] && kill -0 "$$(cat build/logs/heartbeat.pid 2>/dev/null)" 2>/dev/null; then \
		echo "Heartbeat started. Agents launching. Monitor: make agent-monitor"; \
	else \
		echo "ERROR: Heartbeat failed to start. Check build/logs/heartbeat.log"; exit 1; \
	fi

## agents-stop: Stop heartbeat + kill all running agents
agents-stop:
	@./scripts/agent-kill.sh

## agent-analyze: Analyze agent session context usage and re-reads
agent-analyze:
	@./scripts/agent-analyze.sh $(ANALYZE_ARGS)

## ci-agents-install: Install GitHub Actions workflows for CI-based agents
ci-agents-install:
	@./scripts/setup-ci-agents.sh

## ci-agents-check: Check CI agent setup (dry run)
ci-agents-check:
	@./scripts/setup-ci-agents.sh --check

## groom: Groom the issue backlog (triage, prioritize, decompose)
groom:
	@./scripts/agent-runner.sh groomer

## pr-digest: Show prioritized PR review digest
pr-digest:
	@./scripts/pr-digest.sh

# ============================================================
# Housekeeping
# ============================================================

## coverage: Regenerate test-app/COVERAGE.md from source
coverage:
	@python3 "$(PROJECT_DIR)/scripts/gen-coverage.py"

## coverage-check: Verify COVERAGE.md is in sync with source
coverage-check:
	@python3 "$(PROJECT_DIR)/scripts/gen-coverage.py" --check

## commands: Regenerate pepper_ios/pepper_commands.py from Swift handlers
commands:
	@PEPPER_REGEN=1 python3 "$(PROJECT_DIR)/scripts/gen-pepper-commands.py"

## commands-check: Verify pepper_commands.py is in sync with Swift handlers
commands-check:
	@python3 "$(PROJECT_DIR)/scripts/gen-pepper-commands.py" --check

## docs: Regenerate all auto-generated docs
docs: coverage commands

# ============================================================
# Eval
# ============================================================

## eval-score: Score an agent verbose log (LOG=path/to/verbose.log)
eval-score:
	@python3 scripts/eval/eval_score.py --log "$(LOG)"

## eval-run: Run a single eval task (TASK=path/to/task.yaml PROMPT=path/to/variant.md)
eval-run:
	@python3 scripts/eval/eval_run.py --task "$(TASK)" $(if $(PROMPT),--prompt "$(PROMPT)") $(if $(MODE),--mode "$(MODE)") $(if $(FIXTURE),--fixture "$(FIXTURE)")

## eval-compare: Compare baseline vs variant scores (A=score.json B=score.json)
eval-compare:
	@python3 scripts/eval/eval_compare.py --baseline "$(A)" --variant "$(B)"

## eval-batch: Run task x variant matrix (TASKS=dir PROMPTS=dir RUNS=N)
eval-batch:
	@python3 scripts/eval/eval_batch.py --tasks "$(or $(TASKS),eval/tasks)" --prompts "$(or $(PROMPTS),eval/prompts)" --runs "$(or $(RUNS),1)"

## eval-record: Extract replay fixture from a verbose log (LOG=path OUTPUT=path)
eval-record:
	@python3 scripts/eval/eval_record.py --log "$(LOG)" --output "$(OUTPUT)"

## clean: Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf build/
	@echo "Done."

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
