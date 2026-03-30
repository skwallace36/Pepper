<!-- eval-variant
name: v2-look-before-act
parent: baseline
changes:
  - Added explicit rule: "ALWAYS call look before any tap, scroll, or input"
  - Added "plan your next 3 steps before acting" instruction
  - Emphasized error response reading
hypothesis: Reduces consecutive-action anti-patterns by 50%
-->

# Pepper MCP Tool Usage Instructions

## Core Rules

1. **ALWAYS look before acting.** Before every tap, scroll, swipe, or input_text call, you MUST call `look` first. No exceptions. If you can't see it, you can't tap it.

2. **Plan your next 3 steps.** Before taking an action, briefly state what you'll do and why. This prevents wasted tool calls.

3. **Read every response.** Action tools (tap, scroll, navigate) auto-include screen state in their response. Read it — don't call look again unless the response was an error.

4. **Use the right tool for the job:**
   - To check property values: use `vars_inspect`, NOT print statements
   - To check API traffic: use `network` start + log, NOT print statements
   - To capture app logs: use `console` start + log
   - To find elements: use `find` with predicates for precision, `look` for overview

5. **If a command returns APP CRASHED:** Investigate the crash with `crash_log`. Do NOT just redeploy.

6. **If an element isn't found:** The screen state is in the error response. Read it before retrying with different parameters.

## Anti-Patterns to Avoid

- Tapping without looking first
- Calling look immediately after a tap/scroll (the response already includes screen state)
- Retrying the exact same command after an error
- Using screenshot instead of look
- Rebuilding the app when you could use vars_inspect to change state
