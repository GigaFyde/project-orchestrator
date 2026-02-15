#!/bin/bash
# scope-protection.sh — block edits outside an agent's assigned scope
# Example hook for PreToolUse (Edit|Write)

# Requires jq
command -v jq >/dev/null || exit 0

# Need project dir to find scope files and state
[ -n "$CLAUDE_PROJECT_DIR" ] || exit 0

# Read active team from orchestrator state
STATE_FILE="${CLAUDE_PROJECT_DIR}/.claude/orchestrator-state.json"
[ -f "$STATE_FILE" ] || exit 0
TEAM=$(jq -r '.team // empty' "$STATE_FILE" 2>/dev/null)
[ -n "$TEAM" ] || exit 0

# Read scope file for the active team
SCOPE_FILE="${CLAUDE_PROJECT_DIR}/.claude/hooks/scopes/${TEAM}.json"
[ -f "$SCOPE_FILE" ] || exit 0

# Parse input from stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Determine the agent name (from CLAUDE_AGENT_NAME env var if available)
AGENT_NAME="${CLAUDE_AGENT_NAME:-}"
[ -n "$AGENT_NAME" ] || exit 0

# Make file path relative to project dir for matching
REL_PATH="${FILE_PATH#"${CLAUDE_PROJECT_DIR}/"}"

# Check if file is in shared paths
SHARED_MATCH=$(jq -r --arg path "$REL_PATH" '
  (.shared // [])[] | select($path | startswith(.))
' "$SCOPE_FILE" 2>/dev/null | head -1)
[ -n "$SHARED_MATCH" ] && exit 0

# Check if file is in agent's allowed paths
AGENT_MATCH=$(jq -r --arg agent "$AGENT_NAME" --arg path "$REL_PATH" '
  (.[$agent] // [])[] | select($path | startswith(.))
' "$SCOPE_FILE" 2>/dev/null | head -1)
[ -n "$AGENT_MATCH" ] && exit 0

# File is out of scope — block the edit
jq -n --arg reason "File '${REL_PATH}' is outside your assigned scope. Check .claude/hooks/scopes/${TEAM}.json for allowed paths." \
  '{decision: "block", reason: $reason}'
