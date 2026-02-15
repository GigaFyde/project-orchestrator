#!/bin/bash
# scripts/session-context.sh — SessionStart hook: auto-load orchestration context
# Fires on clear/resume to restore implementation context after /clear or session resume.

source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
hook_init

is_hook_enabled "session_context" || exit 0

INPUT=$(cat)
SOURCE=$(echo "$INPUT" | jq -r '.source // empty')

# Only inject on clear/resume, not fresh startup (compact is handled by PreCompact hook)
case "$SOURCE" in
  clear|resume) ;;
  *) exit 0 ;;
esac

# Read active plan from state file (not scanning by status)
ACTIVE_PLAN=$(get_active_plan)
[ -n "$ACTIVE_PLAN" ] || exit 0

# Resolve to absolute path
PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
[ -f "$PLAN_PATH" ] || exit 0

# Extract context
PLAN_NAME=$(get_plan_title "$PLAN_PATH")
COMPLETE=$(count_task_status "$PLAN_PATH" "complete")
IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
PENDING=$(count_task_status "$PLAN_PATH" "pending")
BLOCKED=$(count_task_status "$PLAN_PATH" "blocked")
ESCALATED=$(count_task_status "$PLAN_PATH" "escalated")
TOTAL=$((COMPLETE + IN_PROGRESS + PENDING + BLOCKED + ESCALATED))

# Check for worktree info (matches both "## Worktree" monorepo and "## Worktrees" polyrepo)
WORKTREE_INFO=""
if grep -Eq '^## Worktrees?' "$PLAN_PATH" 2>/dev/null; then
  WORKTREE_INFO=" Worktrees are configured — check the design doc for paths."
fi

CONTEXT="Active implementation: ${PLAN_NAME} (${ACTIVE_PLAN}). Progress: ${COMPLETE}/${TOTAL} tasks complete, ${IN_PROGRESS} in-progress, ${PENDING} pending."
[ "$BLOCKED" -gt 0 ] && CONTEXT="${CONTEXT} ${BLOCKED} blocked."
[ "$ESCALATED" -gt 0 ] && CONTEXT="${CONTEXT} ${ESCALATED} escalated (needs human)."
[ -n "$WORKTREE_INFO" ] && CONTEXT="${CONTEXT}${WORKTREE_INFO}"
CONTEXT="${CONTEXT} Read the design doc for full details: ${ACTIVE_PLAN}"

# Build JSON safely using jq --arg (avoids shell metacharacter issues)
jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $ctx}}'
