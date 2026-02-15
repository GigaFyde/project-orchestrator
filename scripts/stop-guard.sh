#!/bin/bash
# scripts/stop-guard.sh — Stop prevention hook
# Blocks premature session end when implementation tasks are still incomplete.
# Second stop attempt is allowed with a warning.
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
hook_init

is_hook_enabled "stop_guard" || exit 0

INPUT=$(cat)

# Prevent infinite loop — allow stop on second attempt with warning
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  # Re-count tasks (state may have changed since first block)
  ACTIVE_PLAN=$(get_active_plan)
  INCOMPLETE=0
  if [ -n "$ACTIVE_PLAN" ]; then
    PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
    if [ -f "$PLAN_PATH" ]; then
      IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
      PENDING=$(count_task_status "$PLAN_PATH" "pending")
      INCOMPLETE=$((IN_PROGRESS + PENDING))
    fi
  fi
  jq -n --arg ctx "Force-stopping with ${INCOMPLETE} incomplete tasks. Running implementers will continue without lead coordination." \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  exit 0
fi

# Check for active implementation
ACTIVE_PLAN=$(get_active_plan)
[ -n "$ACTIVE_PLAN" ] || exit 0

PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
[ -f "$PLAN_PATH" ] || exit 0

# Count incomplete tasks using portable grep -E
# Only in-progress and pending prevent stopping — blocked/escalated tasks don't
# (they're waiting for human intervention anyway)
IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
PENDING=$(count_task_status "$PLAN_PATH" "pending")
INCOMPLETE=$((IN_PROGRESS + PENDING))

if [ "$INCOMPLETE" -gt 0 ]; then
  PLAN_NAME=$(get_plan_title "$PLAN_PATH")
  jq -n --arg reason "${INCOMPLETE} tasks still incomplete in '${PLAN_NAME}'. Complete implementation or stop again to force-stop." \
    '{decision: "block", reason: $reason}'
  exit 0
fi

exit 0
