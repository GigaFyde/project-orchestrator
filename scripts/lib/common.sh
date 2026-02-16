#!/bin/bash
# scripts/lib/common.sh — shared helpers for hook scripts

# Check dependencies — exit silently if missing (hooks should degrade, not break)
check_deps() {
  command -v jq >/dev/null || { exit 0; }
}

# Resolve project root — handles git worktrees where $CLAUDE_PROJECT_DIR may be unset
# Falls back to git common dir (always points to main repo's .git, even from worktrees)
resolve_project_dir() {
  if [ -n "$CLAUDE_PROJECT_DIR" ] && [ -d "${CLAUDE_PROJECT_DIR}/.claude" ]; then
    echo "$CLAUDE_PROJECT_DIR"
    return
  fi
  # Worktree fallback: derive main repo root from git common dir
  local common_dir
  common_dir=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  [ -n "$common_dir" ] || return 1
  local root="${common_dir%/.git}"
  [ -d "${root}/.claude" ] && echo "$root" || return 1
}

# Standard script preamble — call at top of every hook script
hook_init() {
  check_deps
  # Resolve project dir (handles worktrees)
  CLAUDE_PROJECT_DIR=$(resolve_project_dir) || exit 0
  export CLAUDE_PROJECT_DIR
  [ -n "$CLAUDE_PLUGIN_ROOT" ] || exit 0
}

# Read a simple key from project.yml using grep (no YAML parser needed)
# Supports flat keys like "stop_guard: true" and nested keys like "task_verification: agent"
# Usage: read_hook_config "stop_guard" → "true" or ""
read_hook_config() {
  local key="$1"
  local config="${CLAUDE_PROJECT_DIR}/.claude/project.yml"
  [ -f "$config" ] || { echo ""; return; }
  # Match "  key: value" under hooks: section — simple grep for "key:" anywhere in file
  grep -E "^[[:space:]]*${key}:" "$config" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"'
}

# Check if a hook is enabled (boolean config key)
# Usage: is_hook_enabled "stop_guard" → exit code 0 (enabled) or 1 (disabled)
is_hook_enabled() {
  local value
  value=$(read_hook_config "$1")
  [ "$value" = "true" ]
}

# Read the active plan path from orchestrator state
# Returns empty string if no active plan
get_active_plan() {
  local state="${CLAUDE_PROJECT_DIR}/.project-orchestrator/state.json"
  [ -f "$state" ] || { echo ""; return; }
  jq -r '.active_plan // empty' "$state" 2>/dev/null
}

# Count task statuses in a design doc's implementation tasks table
# Usage: count_task_status "/path/to/design.md" "pending"
# Uses grep -E (portable across GNU and BSD grep)
count_task_status() {
  local doc="$1" status="$2"
  grep -Ec "\|[[:space:]]*${status}[[:space:]]*\|" "$doc" 2>/dev/null || echo "0"
}

# Extract plan title from design doc (finds first "# " heading)
# Falls back to filename if no heading found
get_plan_title() {
  local doc="$1"
  local title
  title=$(grep -m1 '^# ' "$doc" 2>/dev/null | sed 's/^# //')
  [ -n "$title" ] && echo "$title" || basename "$doc" .md
}
