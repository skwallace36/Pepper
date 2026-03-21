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
# Per-simulator port: deterministic hash of SIMULATOR_ID → port in 8770-8869.
PORT          ?= $(shell echo "$(SIMULATOR_ID)" | python3 -c "import sys,hashlib; uid=sys.stdin.read().strip(); print(8770 + int(hashlib.md5(uid.encode()).hexdigest()[:4],16) % 100 if uid else 8765)" 2>/dev/null)

PROJECT_DIR := $(shell pwd)
TOOLS_DIR   := $(PROJECT_DIR)/tools
CONTROL_DIR := $(PROJECT_DIR)/dylib
DYLIB_PATH  := $(PROJECT_DIR)/build/Pepper.framework/Pepper

LOGS_DIR    := $(PROJECT_DIR)/build/logs

.PHONY: help build deploy launch kill relaunch ping check \
        logs clean test-client pepper-ctl test-app

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
	@echo "  SIMULATOR_ID = $(SIMULATOR_ID)"
	@echo "  BUNDLE_ID    = $(BUNDLE_ID)"
	@echo "  PORT         = $(PORT)"

# ============================================================
# Core workflow: build dylib → launch with injection
# ============================================================

## build: Build Pepper.framework dylib
build:
	@bash "$(TOOLS_DIR)/build-dylib.sh"

## launch: Launch app on simulator with Pepper injected
launch:
	@if [ ! -f "$(DYLIB_PATH)" ]; then \
		echo "Pepper.framework not found. Run 'make build' first." >&2; \
		exit 1; \
	fi
	@echo "Launching $(BUNDLE_ID) with Pepper injection..."
	-@xcrun simctl terminate "$(SIMULATOR_ID)" "$(BUNDLE_ID)" 2>/dev/null
	@open -a Simulator --args -CurrentDeviceUDID "$(SIMULATOR_ID)" 2>/dev/null || true
	@sleep 2
	@xcrun simctl privacy "$(SIMULATOR_ID)" grant all "$(BUNDLE_ID)" 2>/dev/null || true
	@xcrun simctl privacy "$(SIMULATOR_ID)" grant photos "$(BUNDLE_ID)" 2>/dev/null || true
	@xcrun simctl privacy "$(SIMULATOR_ID)" grant photos-add "$(BUNDLE_ID)" 2>/dev/null || true
	@SIMCTL_CHILD_DYLD_INSERT_LIBRARIES="$(DYLIB_PATH)" \
		SIMCTL_CHILD_PEPPER_PORT="$(PORT)" \
		SIMCTL_CHILD_PEPPER_SIM_UDID="$(SIMULATOR_ID)" \
		SIMCTL_CHILD_PEPPER_ADAPTER="$(ADAPTER_TYPE)" \
		xcrun simctl launch "$(SIMULATOR_ID)" "$(BUNDLE_ID)"
	@echo "Launched with injection. Control plane at ws://localhost:$(PORT)"

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

## check: Run all pre-commit checks (build, syntax, MCP, paths)
check:
	@bash "$(PROJECT_DIR)/scripts/pre-commit"

# ============================================================
# Control plane commands
# ============================================================

## ping: Quick health check — test if control plane is responding
ping:
	@python3 "$(TOOLS_DIR)/pepper-ctl" --port $(PORT) ping

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

# ============================================================
# Housekeeping
# ============================================================

## clean: Clean build artifacts
clean:
	@echo "Cleaning build artifacts..."
	@rm -rf build/
	@echo "Done."
