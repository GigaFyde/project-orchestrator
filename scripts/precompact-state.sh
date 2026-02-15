#!/bin/bash
# scripts/precompact-state.sh — PreCompact state preservation hook
# Injects orchestration state into compaction context so it survives summarization.
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
hook_init

is_hook_enabled "precompact_state" || exit 0

# Read active plan from state file
ACTIVE_PLAN=$(get_active_plan)
[ -n "$ACTIVE_PLAN" ] || exit 0

PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
[ -f "$PLAN_PATH" ] || exit 0

# Read state file for team info
STATE_FILE="${CLAUDE_PROJECT_DIR}/.claude/orchestrator-state.json"
TEAM=$(jq -r '.team // empty' "$STATE_FILE" 2>/dev/null)
SLUG=$(jq -r '.slug // empty' "$STATE_FILE" 2>/dev/null)

# Extract task counts
PLAN_NAME=$(get_plan_title "$PLAN_PATH")
COMPLETE=$(count_task_status "$PLAN_PATH" "complete")
IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
PENDING=$(count_task_status "$PLAN_PATH" "pending")
TOTAL=$((COMPLETE + IN_PROGRESS + PENDING))

CONTEXT="ORCHESTRATION STATE — preserve this across compaction. Plan: ${PLAN_NAME} (${ACTIVE_PLAN}). Team: ${TEAM}. Progress: ${COMPLETE}/${TOTAL} tasks complete. Read the design doc after compaction to restore full context."

# Build JSON safely using jq --arg
jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "PreCompact", additionalContext: $ctx}}'
