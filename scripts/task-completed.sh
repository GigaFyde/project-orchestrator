#!/bin/bash
# scripts/task-completed.sh — TaskCompleted verification gate
# Dispatches to agent (thorough) or prompt (lightweight) verification
# based on hooks.task_verification config in consumer's project.yml

source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
hook_init

# Check if task verification is enabled
VERIFICATION=$(read_hook_config "task_verification")
[ -n "$VERIFICATION" ] && [ "$VERIFICATION" != "off" ] || exit 0

# Only verify during active implementation sessions
ACTIVE_PLAN=$(get_active_plan)
[ -n "$ACTIVE_PLAN" ] || exit 0

INPUT=$(cat)
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // empty')
TASK_ID=$(echo "$INPUT" | jq -r '.task_id // empty')

if [ "$VERIFICATION" = "agent" ]; then
  CONTEXT="Verify this task completion against the design doc at ${ACTIVE_PLAN}."
  CONTEXT="${CONTEXT} Task #${TASK_ID}: ${TASK_SUBJECT}."
  CONTEXT="${CONTEXT} Check: 1) Files mentioned exist and contain expected changes."
  CONTEXT="${CONTEXT} 2) A commit was created. 3) Task spec requirements from the design doc are met."

  jq -n --arg ctx "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "TaskCompleted", additionalContext: $ctx}}'

elif [ "$VERIFICATION" = "prompt" ]; then
  CONTEXT="Lightweight verification: check that the task completion for '${TASK_SUBJECT}'"
  CONTEXT="${CONTEXT} includes a commit SHA, list of files changed, and test results."
  CONTEXT="${CONTEXT} Design doc: ${ACTIVE_PLAN}."

  jq -n --arg ctx "$CONTEXT" \
    '{hookSpecificOutput: {hookEventName: "TaskCompleted", additionalContext: $ctx}}'
fi
