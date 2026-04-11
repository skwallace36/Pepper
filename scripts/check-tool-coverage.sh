#!/usr/bin/env bash
# Verify every MCP tool has a matching dylib handler.
# Catches mismatches like #323 (flags tool with no handler) at PR time.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# --- 1. Extract MCP tool names from @mcp.tool() decorated functions ---
mcp_tools=()
while IFS= read -r name; do
  [[ -n "$name" ]] && mcp_tools+=("$name")
done < <(grep -A1 '@mcp\.tool()' "$ROOT"/pepper_ios/mcp_server.py "$ROOT"/pepper_ios/mcp_tools_*.py | grep 'async def ' | sed -E 's/.*async def ([a-z_][a-z0-9_]*)\(.*/\1/' | sort -u)

# --- 2. Extract dylib handler command names ---
dylib_commands=()

# Handler files: let commandName = "xxx"
while IFS= read -r name; do
  [[ -n "$name" ]] && dylib_commands+=("$name")
done < <(grep -h 'let commandName = ' "$ROOT"/dylib/commands/handlers/*.swift | sed -E 's/.*let commandName = "([^"]+)".*/\1/' | sort -u)

# Inline commands from PepperDispatcher.swift
while IFS= read -r name; do
  [[ -n "$name" ]] && dylib_commands+=("$name")
done < <(grep -E 'register\("[a-z_]+"' "$ROOT"/dylib/commands/PepperDispatcher.swift | sed -E 's/.*register\("([^"]+)".*/\1/' | sort -u)

# --- 3. Allowlists ---

# MCP tools that don't send a dylib command (local-only).
local_only=(
  biometric
  build_sim
  build_hardware
  crash_log
  deploy_sim
  http_call
  raw
  record
  script
  simulator
)

# MCP tool name -> dylib command name (where they differ).
map_tool_name() {
  case "$1" in
    input_text)    echo "input" ;;
    read_element)  echo "read" ;;
    undo_manager)  echo "undo" ;;
    vars_inspect)  echo "vars" ;;
    look)          echo "introspect" ;;
    pepper_assert) echo "assert" ;;
    *)             echo "$1" ;;
  esac
}

# --- 4. Check coverage ---
missing=()
for tool in "${mcp_tools[@]}"; do
  skip=false
  for lo in "${local_only[@]}"; do
    if [[ "$tool" == "$lo" ]]; then
      skip=true
      break
    fi
  done
  $skip && continue

  target="$(map_tool_name "$tool")"

  found=false
  for cmd in "${dylib_commands[@]}"; do
    if [[ "$cmd" == "$target" ]]; then
      found=true
      break
    fi
  done

  if ! $found; then
    missing+=("$tool -> $target")
  fi
done

# --- 5. Report ---
if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: ${#missing[@]} MCP tool(s) have no matching dylib handler:"
  for m in "${missing[@]}"; do
    echo "  - $m"
  done
  echo ""
  echo "Fix: add a handler in dylib/commands/handlers/, or add to"
  echo "local_only in scripts/check-tool-coverage.sh if no handler is needed."
  exit 1
fi

echo "OK: all ${#mcp_tools[@]} MCP tools have matching dylib handlers (${#local_only[@]} local-only skipped)"
