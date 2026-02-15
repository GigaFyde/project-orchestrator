# Plugin Hooks for Project Orchestrator

**Status:** complete
**Created:** 2026-02-16
**Slug:** plugin-hooks

## Problem

The project-orchestrator plugin currently ships zero hooks. The orchestration workflow has several quality and context gaps that hooks could fill:

1. **Teammates can mark tasks complete without verification** — no automated quality gate
2. **Context lost on `/clear` and compaction** — orchestration state disappears
3. **No scope enforcement** — teammates can edit files outside their assigned task
4. **No notifications** — long parallel runs require manual monitoring
5. **Premature stopping** — agent can declare "done" while tasks remain in-progress

## Hook Events Available

Claude Code provides 14 hook events. After analysis, **8 are relevant** to this plugin:

| Event | Can Block? | Relevance |
|-------|-----------|-----------|
| TaskCompleted | Yes | Verify task deliverables before completion |
| Stop | Yes | Prevent premature "I'm done" |
| SubagentStop | Yes | Quality gate on teammate output |
| TeammateIdle | Yes | Check work quality before going idle |
| PreToolUse | Yes | Scope protection for file edits |
| SessionStart | No | Auto-load orchestration context |
| PreCompact | No | Preserve orchestration state |
| Notification | No | Alert user during parallel runs |

Three hook types available: **command** (shell scripts), **prompt** (single-turn LLM), **agent** (multi-turn LLM with tools).

## Decisions

### Distribution
- **Format:** `hooks/hooks.json` — auto-discovered by Claude Code when plugin is installed
- **Scripts:** `scripts/` directory, referenced via `${CLAUDE_PLUGIN_ROOT}/scripts/`
- **Activation:** All hooks are **opt-in** via `project.yml` — nothing fires until explicitly enabled
- **TaskCompleted type:** Defaults to **agent** (thorough verification), configurable to `prompt` or `off`

### Configuration Schema

Consumer projects enable hooks in `.claude/project.yml`:

```yaml
# .claude/project.yml
hooks:
  task_verification: "agent"    # "agent" (default when enabled) | "prompt" | "off"
  stop_guard: true              # default: false (opt-in)
  session_context: true         # default: false (opt-in)
  precompact_state: true        # default: false (opt-in)
```

**Config validation rules:**

| Condition | Behavior |
|-----------|----------|
| Missing `.claude/project.yml` | All hooks disabled (exit 0) |
| Missing `hooks` section | All hooks disabled (exit 0) |
| Missing individual hook key | That hook disabled (treated as `false` / `"off"`) |
| `hooks.task_verification` not `"agent"`, `"prompt"`, or `"off"` | Error: "hooks.task_verification must be 'agent', 'prompt', or 'off'" |
| `hooks.*` boolean key set to non-boolean | Error: "hooks.{key} must be true or false" |

The `hooks/hooks.json` in the plugin registers all 4 hook events. Each hook's command script checks `project.yml` at runtime — if the config key is missing or false, the script exits 0 immediately (no-op).

### Plugin Directory Structure

```
project-orchestrator/
├── .claude-plugin/plugin.json
├── hooks/
│   └── hooks.json              # Hook event → script mappings
├── scripts/
│   ├── lib/
│   │   └── common.sh           # Shared helpers: config reading, dependency checks
│   ├── task-completed.sh       # TaskCompleted verification gate
│   ├── stop-guard.sh           # Stop prevention
│   ├── session-context.sh      # SessionStart context injection
│   └── precompact-state.sh     # PreCompact state preservation
├── agents/
├── commands/
├── skills/
└── docs/
```

### Active Plan Tracking

To avoid ambiguity when multiple plans have status `implementing`, the `/project:implement` command writes an active plan marker:

```json
// .claude/orchestrator-state.json (written by implement command, read by hooks)
{
  "active_plan": "docs/plans/2026-02-16-plugin-hooks-design.md",
  "slug": "plugin-hooks",
  "team": "implement-plugin-hooks",
  "started": "2026-02-16T10:00:00Z",
  "worktrees": {}
}
```

**Worktree field structure:**
```json
// Polyrepo — per-service worktrees
{ "worktrees": { "api": "/abs/path/to/worktree-api", "frontend": "/abs/path/to/worktree-frontend" } }

// Monorepo — single worktree
{ "worktrees": { "_all": "/abs/path/to/worktree" } }

// No worktrees
{ "worktrees": {} }
```

Hook scripts read this file instead of scanning for `Status:.*implementing`. If the file doesn't exist, hooks that depend on an active plan exit 0 (no-op).

**Lifecycle:**
- Written **before** `TeamCreate` at implement step 6 (so hooks can find it immediately when implementation starts)
- Must use atomic writes: write to temp file, then `mv` to final path (prevents read-during-write corruption)
- Deleted **after** `TeamDelete` at implement step 10
- If `TeamCreate` fails after state file is written, clean up the state file

## Hook Script Interface

All command hook scripts follow the same pattern:

### Input

Claude Code sends JSON via **stdin** containing event-specific fields:

| Field | Events | Description |
|-------|--------|-------------|
| `session_id` | All | Current session identifier |
| `cwd` | All | Current working directory |
| `hook_event_name` | All | Event name (e.g., `"TaskCompleted"`) |
| `stop_hook_active` | Stop only | `true` if Stop hook already fired once this turn (prevents infinite loops) |
| `source` | SessionStart only | How session started: `"startup"`, `"resume"`, `"clear"`, `"compact"` |
| `tool_name` | PreToolUse only | Name of tool being called |
| `tool_input` | PreToolUse only | Tool parameters (e.g., `file_path` for Edit/Write) |
| `task_subject` | TaskCompleted only | Task title |
| `task_id` | TaskCompleted only | Task identifier |

### Output

Scripts return JSON via **stdout**:

**To block (exit 0):**
```json
{"decision": "block", "reason": "Human-readable explanation fed back to Claude"}
```

**To inject context (exit 0):**
```json
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "Text injected into Claude's context"
  }
}
```

**To allow (exit 0):** Output nothing, or `{}`.

**To signal error (exit 2):** Write reason to stderr. Claude receives it as feedback.

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success — stdout JSON is processed |
| 2 | Blocking error — stderr text fed back to Claude as reason |
| Other | Non-blocking error — logged, execution continues |

### Environment Variables

| Variable | Guaranteed | Description |
|----------|-----------|-------------|
| `CLAUDE_PROJECT_DIR` | Yes | Absolute path to project root |
| `CLAUDE_PLUGIN_ROOT` | Yes (in plugin hooks) | Absolute path to plugin directory |

### Dependencies

Scripts require:
- **`jq`** — for parsing JSON stdin. All scripts check `command -v jq >/dev/null` and exit 0 if missing.
- **No YAML parser needed** — scripts use `grep` on flat `project.yml` keys (see Common Library below).

### Common Library (`scripts/lib/common.sh`)

Shared helpers sourced by all hook scripts:

```bash
#!/bin/bash
# scripts/lib/common.sh — shared helpers for hook scripts

# Check dependencies — exit silently if missing (hooks should degrade, not break)
check_deps() {
  command -v jq >/dev/null || { exit 0; }
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
  local state="${CLAUDE_PROJECT_DIR}/.claude/orchestrator-state.json"
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

# Extract plan title from design doc (skips "**Status:**" metadata lines, finds first "# " heading)
# Falls back to filename if no heading found
get_plan_title() {
  local doc="$1"
  local title
  title=$(grep -m1 '^# ' "$doc" 2>/dev/null | sed 's/^# //')
  [ -n "$title" ] && echo "$title" || basename "$doc" .md
}

# Standard script preamble — call at top of every hook script
hook_init() {
  check_deps
  # Verify environment
  [ -n "$CLAUDE_PROJECT_DIR" ] || exit 0
  [ -n "$CLAUDE_PLUGIN_ROOT" ] || exit 0
}
```

**Key design choices:**
- **No YAML parser dependency** — `read_hook_config` uses `grep` + `sed` on flat key patterns. This works because all hook config keys are simple scalars under `hooks:`, not nested objects.
- **Portable regex** — all scripts use `grep -E` (extended regex), which works on both GNU and BSD (macOS) grep. Never use `\|` (basic regex OR) which fails on BSD.
- **Silent degradation** — missing `jq`, missing config, missing env vars all result in `exit 0` (allow), never a crash.

## Proposed Hooks

### 1. TaskCompleted — Deliverable Verification Gate

**Priority:** High
**Type:** agent hook (default), configurable to prompt
**Event:** TaskCompleted

**Problem:** Implementer teammates self-review via checklist, but there's no automated verification that the task spec was actually fulfilled. The spec-reviewer agent exists but runs as a manual post-implementation step.

**Scope:** Only fires for tasks created during `/project:implement` — detected by checking if `.claude/orchestrator-state.json` exists (active implementation session). Brainstorm/review tasks are not verified.

**Proposed behavior:**
- Script reads `project.yml` to check if enabled (`hooks.task_verification`)
- If disabled, missing, or `"off"`: exits 0 (no-op)
- If no `.claude/orchestrator-state.json`: exits 0 (not in an implementation session)
- If `"agent"`: returns JSON declaring an agent hook with prompt that includes the active plan path
- If `"prompt"`: returns JSON declaring a prompt hook for lightweight format checking
- Blocks completion if verification fails, providing reason

**How the agent gets context:**
The script reads `.claude/orchestrator-state.json` to get the active plan path, then embeds it in the agent's prompt. The agent can then:
1. Read the design doc to find the task spec
2. Read files listed in `$ARGUMENTS` (task subject/description)
3. Check git log for recent commits
4. Verify the implementation matches the spec

**Performance impact:**
- Agent hook adds ~30-120s per task completion
- For a 6-task implementation with 3 parallel workers, expect +3-12 minutes total if all tasks verify serially
- Prompt hook adds ~5s per task (format check only, can't read files)
- Projects prioritizing speed should use `"prompt"` mode

**Trade-offs:**
- Agent is default because thoroughness matters more than speed for catching spec violations — real spec verification happens here, not just in `/project:review`
- Prompt hook is a lightweight alternative that checks report structure (commit SHA present? files listed?) without reading actual files

**Task completion report contract:**
The implementer skill's "Reporting to Lead" section defines the report format. The implementer must follow this ordering:

1. **First:** Call `TaskUpdate` with completion metadata (atomic with status change):
```
TaskUpdate(taskId, status: "completed", metadata: {
  "commit": "abc1234",
  "files_changed": ["src/handler.ts", "src/handler.test.ts"],
  "tests_passed": true,
  "design_doc": "docs/plans/2026-02-16-plugin-hooks-design.md"
})
```
2. **Then:** Send the completion report via `SendMessage` to the lead

This ordering ensures the TaskCompleted hook fires with metadata already populated. The metadata is independent of MCP `save_state` (which is for resuming mid-task, not for hook verification).

The hook reads task metadata from `$ARGUMENTS` (which contains the task subject and any metadata).

**Hook failure modes:**
- Task has no metadata → hook injects generic "verify task completion" context (no block)
- `design_doc` path doesn't exist → hook warns but doesn't block
- Metadata is malformed → hook degrades to format-only check

**Example script (`scripts/task-completed.sh`):**
```bash
#!/bin/bash
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

if [ "$VERIFICATION" = "agent" ]; then
  # Return agent hook declaration — Claude Code spawns the agent
  cat <<AGENT_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "TaskCompleted",
    "additionalContext": "Verify this task completion against the design doc at ${ACTIVE_PLAN}. Task: ${TASK_SUBJECT}. Check: 1) Files mentioned exist and contain expected changes. 2) A commit was created. 3) Task spec requirements from the design doc are met."
  }
}
AGENT_JSON
elif [ "$VERIFICATION" = "prompt" ]; then
  cat <<PROMPT_JSON
{
  "hookSpecificOutput": {
    "hookEventName": "TaskCompleted",
    "additionalContext": "Lightweight verification: check that the task completion for '${TASK_SUBJECT}' includes a commit SHA, list of files changed, and test results. Design doc: ${ACTIVE_PLAN}."
  }
}
PROMPT_JSON
fi
```

> **Validated (Task 1):** Command hooks cannot dynamically dispatch to agent/prompt types. The command hook returns `additionalContext` via `hookSpecificOutput`, which injects verification instructions into Claude's context. The depth of verification (thorough vs lightweight) is controlled by the injected text, not by spawning a separate hook type. See the `hooks.json` structure below for the final registration.

---

### 2. Stop — Prevent Premature Session End

**Priority:** High
**Type:** command hook
**Event:** Stop
**Timeout:** 5 seconds

**Problem:** The lead orchestrator agent can stop responding while implementation tasks are still in-progress or pending. This leaves the team in limbo.

**Proposed behavior:**
- Fires when the main agent is about to stop
- Checks `stop_hook_active` (provided by Claude Code in the input JSON) — if `true`, this is the second stop attempt; allow it through with a warning that implementers may still be running
- Reads `.claude/orchestrator-state.json` for the active plan path
- If no active plan: exits 0 (allow stop)
- Reads the design doc and counts incomplete tasks using `count_task_status`
- Blocks if any tasks are `in-progress` or `pending`
- Allows stopping if all tasks are `complete`, `blocked`, or `escalated`

**On second stop (stop_hook_active=true):**
The hook allows the stop but injects a warning: "Stopping with incomplete tasks. Running implementer subagents will continue until they finish or timeout, but the lead is no longer present to coordinate." This prevents infinite loops while informing the user of consequences.

**Example script (`scripts/stop-guard.sh`):**
```bash
#!/bin/bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
hook_init

is_hook_enabled "stop_guard" || exit 0

INPUT=$(cat)

# Prevent infinite loop — allow stop on second attempt with warning
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false')
if [ "$STOP_ACTIVE" = "true" ]; then
  # Re-count tasks (state may have changed since first block)
  ACTIVE_PLAN=$(get_active_plan)
  PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
  INCOMPLETE=0
  if [ -n "$ACTIVE_PLAN" ] && [ -f "$PLAN_PATH" ]; then
    IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
    PENDING=$(count_task_status "$PLAN_PATH" "pending")
    INCOMPLETE=$((IN_PROGRESS + PENDING))
  fi
  jq -n --arg ctx "Force-stopping with ${INCOMPLETE} incomplete tasks. Running implementers will continue without lead coordination." \
    '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $ctx}}'
  exit 0
fi

# Check for active implementation
ACTIVE_PLAN=$(get_active_plan)
[ -n "$ACTIVE_PLAN" ] || exit 0
[ -f "$ACTIVE_PLAN" ] || exit 0

# Count incomplete tasks using portable grep -E
# Only in-progress and pending prevent stopping — blocked/escalated tasks don't
# (they're waiting for human intervention anyway)
PLAN_PATH="${CLAUDE_PROJECT_DIR}/${ACTIVE_PLAN}"
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
```

---

### 3. PreToolUse (Edit/Write) — Scope Protection

**Priority:** Medium
**Type:** command hook
**Event:** PreToolUse (matcher: `Edit|Write`)

**Problem:** During parallel implementation, teammates can accidentally edit files outside their assigned scope. The component-first isolation mode helps but isn't enforced — it's advisory text in the task prompt.

**Proposed behavior:**
- Fires before any Edit or Write tool call
- Reads a scope file (e.g., `.claude/hooks/scopes/{team}.json`) listing allowed paths per agent
- Denies edits to files not in the agent's scope
- Only active during team implementation sessions

**Trade-offs:**
- Requires scope file infrastructure (currently documented in README but not shipped)
- Could be too rigid — sometimes agents legitimately need to edit adjacent files
- The plugin currently leaves scope management to consumer projects
- Shipped as a **template/example** in `examples/hooks/scope-protection/`, not a built-in hook

**Current state:** The README already documents this pattern. The plugin ships a reference implementation as an example, not in `hooks/hooks.json`.

---

### 4. SessionStart — Auto-Load Orchestration Context

**Priority:** Medium
**Type:** command hook
**Event:** SessionStart (matcher: `clear|resume`)
**Timeout:** 5 seconds

**Problem:** After `/clear`, the agent loses all context about the current implementation — what design doc is active, which tasks are done, what wave is in progress. Users must manually remind the agent.

**Proposed behavior:**
- Fires on session start after `/clear` or resume (NOT on `compact` — PreCompact handles that)
- Reads `.claude/orchestrator-state.json` for the active plan path (not file scanning)
- If no active plan: exits 0 (no context to inject)
- Reads the design doc and extracts:
  - Plan title and path
  - Task completion progress (X of Y complete)
  - Worktree paths (if `## Worktree` / `## Worktrees` section exists)
  - Any blocked/escalated tasks
- Injects summary via `additionalContext`

**Why both SessionStart and PreCompact?**
- **SessionStart** fires after `/clear` (user-initiated) and resume — restores context from scratch
- **PreCompact** fires before automated compaction — preserves context that might be lost in summarization
- They fire at different lifecycle points and serve complementary purposes
- SessionStart reads from disk (state file + design doc), PreCompact adds to the compaction context

**Example script (`scripts/session-context.sh`):**
```bash
#!/bin/bash
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
```

---

### 5. PreCompact — Preserve Orchestration State

**Priority:** Medium
**Type:** command hook
**Event:** PreCompact
**Timeout:** 5 seconds

**Problem:** When context auto-compacts, the summary may lose critical orchestration details — which tasks are assigned to whom, what wave is running, worktree paths, etc.

**What gets preserved:**
- Active plan path and title
- Task status counts (complete/in-progress/pending/blocked/escalated)
- Worktree paths (if configured)
- Team name (from `orchestrator-state.json`)

**How it's injected:** Same `additionalContext` mechanism as SessionStart — the text is included in the compaction context, so the summarizer preserves it.

**Example script (`scripts/precompact-state.sh`):**
```bash
#!/bin/bash
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

# Extract context (same logic as session-context.sh)
PLAN_NAME=$(get_plan_title "$PLAN_PATH")
COMPLETE=$(count_task_status "$PLAN_PATH" "complete")
IN_PROGRESS=$(count_task_status "$PLAN_PATH" "in-progress")
PENDING=$(count_task_status "$PLAN_PATH" "pending")
TOTAL=$((COMPLETE + IN_PROGRESS + PENDING))

CONTEXT="ORCHESTRATION STATE — preserve this across compaction. Plan: ${PLAN_NAME} (${ACTIVE_PLAN}). Team: ${TEAM}. Progress: ${COMPLETE}/${TOTAL} tasks complete. Read the design doc after compaction to restore full context."

# Build JSON safely using jq --arg
jq -n --arg ctx "$CONTEXT" '{hookSpecificOutput: {hookEventName: "PreCompact", additionalContext: $ctx}}'
```

---

### 6. SubagentStop — Teammate Quality Gate

**Priority:** Low-Medium
**Type:** prompt hook
**Event:** SubagentStop (matcher: `implement-.*`)

**Recommendation:** Skip this in favor of TaskCompleted (#1). They overlap significantly — TaskCompleted is more reliable because it has structured task data.

---

### 7. Notification — Desktop Alerts for Parallel Runs

**Priority:** Low
**Type:** command hook
**Event:** Notification (matcher: `permission_prompt|idle_prompt`)

**Recommendation:** Document as a recommended companion setup in README, don't ship in this plugin. Not orchestration-specific.

---

### 8. TeammateIdle — Work Quality Check

**Priority:** Low
**Type:** command hook
**Event:** TeammateIdle

**Recommendation:** Skip — TeammateIdle fires after every agent turn, too frequent for quality checks. Overlaps with TaskCompleted.

---

## hooks.json Structure

The `hooks/hooks.json` file registers all hook events. Command scripts handle opt-in logic internally (exit 0 if not enabled).

For TaskCompleted, we register both agent and prompt variants. The command script determines which is active based on config, and the unused one exits immediately.

```json
{
  "hooks": {
    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/task-completed.sh",
            "timeout": 10
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/stop-guard.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "clear|resume",
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/session-context.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${CLAUDE_PLUGIN_ROOT}/scripts/precompact-state.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

> **Validated (Task 1):** Command hooks CANNOT dynamically dispatch to agent/prompt types at runtime. Hook types are statically configured in JSON. The command hook approach works by injecting `additionalContext` into Claude's context via `hookSpecificOutput` — this provides verification instructions that Claude acts on within its current turn, rather than spawning a separate agent subprocess. This is sufficient for both "agent-style" (thorough) and "prompt-style" (lightweight) verification, since the injected context controls the depth of verification Claude performs. The trade-off: no enforced isolation between verification and the completing agent's context, unlike a true agent hook. If stricter isolation is needed later, register a separate `type: "agent"` hook entry that checks config internally (incurs agent spawn overhead even when disabled).

## Summary: Recommended Implementation

| Priority | Hook | Type | Ship in Plugin? | Default | Timeout |
|----------|------|------|-----------------|---------|---------|
| **High** | TaskCompleted verification | agent (configurable) | Yes — opt-in | agent | 120s (agent) / 30s (prompt) / 10s (command) |
| **High** | Stop prevention | command | Yes — opt-in | off | 5s |
| **Medium** | SessionStart context | command | Yes — opt-in | off | 5s |
| **Medium** | PreCompact state | command | Yes — opt-in | off | 5s |
| **Medium** | PreToolUse scope | command | Template/example only | — | — |
| **Low** | SubagentStop | prompt | Skip (overlaps TaskCompleted) | — | — |
| **Low** | Notification | command | Document in README only | — | — |
| **Low** | TeammateIdle | command | Skip (too frequent) | — | — |

**Scope: 4 hooks to ship (all opt-in), 1 template, 2 documented**

All hooks require explicit opt-in via `project.yml`. No hooks fire unless the consumer project enables them. Missing config, missing dependencies, or missing env vars all result in silent no-op (exit 0).

## Services Affected

- `project-orchestrator` (this plugin only — pure markdown + shell scripts, no external services)

## Pre-Implementation Validation

Task 1 validated these assumptions against Claude Code's hook API:

1. **Can a command hook dynamically dispatch to agent/prompt?** — **No.** Hook types are statically configured in JSON. The command hook approach works via `additionalContext` injection — the depth of verification is controlled by the injected text content, not by spawning a different hook type. Current design (single command hook) is sufficient. For stricter isolation, register a separate `type: "agent"` entry in the future.

2. **What fields does TaskCompleted provide?** — Input JSON includes: `task_id`, `task_subject`, `task_description` (optional), `teammate_name` (optional), `team_name` (optional), plus standard fields (`session_id`, `cwd`, `hook_event_name`). Task metadata set via `TaskUpdate` is NOT directly in the hook input — the hook must read `orchestrator-state.json` and the design doc for plan context.

3. **Does `$CLAUDE_PROJECT_DIR` point to the main repo root when hooks fire inside worktrees?** — Not yet validated at runtime. Scripts already handle this gracefully: if `orchestrator-state.json` isn't found at `$CLAUDE_PROJECT_DIR/.claude/`, hooks exit 0 (no-op). Worktree resolution can be addressed when worktree support is tested.

**Result:** No changes needed to hooks.json structure. The command hook approach with `additionalContext` injection is confirmed viable. Tasks 2-6 can proceed.

## Implementation Tasks

| # | Task | Depends On | Status |
|---|------|------------|--------|
| 1 | Create `hooks/hooks.json` — register all 4 hook events with command scripts. Validate against Claude Code's hook schema. Verify whether command hooks can dynamically dispatch to agent/prompt types for TaskCompleted. | — | complete | impl-task-1 |
| 2 | Create `scripts/lib/common.sh` — shared helpers: `hook_init`, `check_deps`, `read_hook_config`, `is_hook_enabled`, `get_active_plan`, `count_task_status`, `get_plan_title`. All use portable `grep -E`. | — | complete | impl-task-2 |
| 3 | Write `scripts/task-completed.sh` — reads config, checks for active implementation session, dispatches to agent/prompt/off. Uses `orchestrator-state.json` for plan path. | 1, 2 | complete | impl-task-5 |
| 4 | Write `scripts/stop-guard.sh` — reads config, checks `stop_hook_active`, reads active plan, counts incomplete tasks. Second stop allowed with warning. | 1, 2 | complete | impl-task-4 |
| 5 | Write `scripts/session-context.sh` — reads config, checks source (clear/resume/compact), reads active plan, extracts progress + worktree info, injects via `additionalContext`. | 1, 2 | complete | impl-task-5 |
| 6 | Write `scripts/precompact-state.sh` — reads config, reads active plan + team info, injects preservation context. | 1, 2 | complete | impl-task-4 |
| 7 | Update implement command to write/delete `.claude/orchestrator-state.json` — write at step 6 (team creation), delete at step 10 (completion). Include `active_plan`, `slug`, `team`, `started`, `worktrees`. | — | complete | impl-task-7 |
| 8 | Update implementer skill to include `design_doc` in TaskUpdate metadata — so TaskCompleted hook can find the design doc path from task data. | — | complete | impl-task-7 |
| 9 | Update README — add "## Plugin Hooks" section after "Project Config" with: hook overview, config schema with `hooks.*` keys, per-hook docs (purpose, trade-offs, when to enable), performance expectations. | 3,4,5,6 | complete | impl-task-9 |
| 10 | Add scope protection example to `examples/hooks/scope-protection/` — example `hooks.json` snippet, `scope-protection.sh` script, setup README. | — | complete | impl-task-2 |

### Acceptance Criteria per Task

**Task 1:**
- [ ] `hooks/hooks.json` validates against Claude Code hook schema
- [ ] All 4 events registered (TaskCompleted, Stop, SessionStart, PreCompact)
- [ ] Script paths use `${CLAUDE_PLUGIN_ROOT}/scripts/`
- [ ] Timeouts specified per hook (5s for command, 10s for task-completed dispatcher)
- [ ] Documented finding: can command hooks dispatch to agent/prompt at runtime?

**Task 2:**
- [ ] All helpers use portable `grep -E` (no `\|` basic regex)
- [ ] All `sed` commands use portable syntax (no `-r` flag, no GNU-specific escapes)
- [ ] `hook_init` checks for `jq`, `$CLAUDE_PROJECT_DIR`, and `$CLAUDE_PLUGIN_ROOT` — exits 0 if missing
- [ ] `read_hook_config` handles missing file, missing key, empty value
- [ ] `get_active_plan` reads from `.claude/orchestrator-state.json`, not file scanning
- [ ] `count_task_status` matches `| status |` pattern in markdown tables
- [ ] `get_plan_title` finds first `# ` heading, falls back to filename if no heading found
- [ ] All JSON output constructed with `jq -n --arg` (not string interpolation)
- [ ] Scripts are `chmod +x`

**Task 3:**
- [ ] Reads `hooks.task_verification` from config
- [ ] Exits 0 if `"off"`, missing, or no config file
- [ ] Exits 0 if no `.claude/orchestrator-state.json` (not in implementation session)
- [ ] If `"agent"`: returns context with plan path for agent verification
- [ ] If `"prompt"`: returns context for lightweight format check
- [ ] Script is `chmod +x`

**Task 4:**
- [ ] Reads `hooks.stop_guard` from config
- [ ] Checks `stop_hook_active` — allows second stop with warning
- [ ] Uses `get_active_plan` (not file scanning)
- [ ] Counts `in-progress` + `pending` tasks using `count_task_status`
- [ ] Blocks with human-readable reason including plan name and count
- [ ] Exits 0 (allow) if no active plan or no incomplete tasks

**Task 5:**
- [ ] Reads `hooks.session_context` from config
- [ ] Filters by `source` — only `clear` and `resume` (NOT `compact` — PreCompact handles that)
- [ ] Uses `get_active_plan` (not file scanning)
- [ ] Extracts: plan title, task progress, worktree info, blocked/escalated counts
- [ ] Detects both `## Worktree` (monorepo) and `## Worktrees` (polyrepo) headings
- [ ] JSON built with `jq -n --arg` (not string interpolation)
- [ ] Returns `additionalContext` with actionable summary

**Task 6:**
- [ ] Reads `hooks.precompact_state` from config
- [ ] Reads both `orchestrator-state.json` (team, slug) and design doc (task counts)
- [ ] Context string explicitly says "preserve this across compaction"
- [ ] JSON built with `jq -n --arg` (not string interpolation)

**Task 7:**
- [ ] `orchestrator-state.json` written BEFORE `TeamCreate` at implement command step 6
- [ ] Uses atomic writes: write to temp file, then `mv` to final path
- [ ] Contains: `active_plan` (relative path), `slug`, `team`, `started`, `worktrees`
- [ ] Deleted AFTER `TeamDelete` at implement command step 10 (completion)
- [ ] If `TeamCreate` fails after state file is written, clean up the state file
- [ ] If worktrees configured, `worktrees` field uses structure from design doc (polyrepo: service→path map, monorepo: `_all`→path)

**Task 8:**
- [ ] Implementer skill documents `TaskUpdate` call BEFORE `SendMessage` report
- [ ] `TaskUpdate` is atomic with status change (single call: `status: "completed"` + `metadata`)
- [ ] Metadata includes: `commit`, `files_changed`, `tests_passed`, `design_doc`
- [ ] `design_doc` value is read from the living state doc path (provided in task prompt)
- [ ] TaskUpdate metadata is independent of MCP `save_state` (different purposes)
- [ ] Hook handles missing metadata gracefully (warns, doesn't block)

**Task 9:**
- [ ] New "## Plugin Hooks" section in README after "Project Config"
- [ ] Documents all 4 shipped hooks with purpose and when to enable
- [ ] Shows config schema example with `hooks.*` keys
- [ ] Includes performance expectations ("agent adds 30-120s per task")
- [ ] Links to scope protection example in `examples/`

**Task 10:**
- [ ] `examples/hooks/scope-protection/README.md` with setup instructions
- [ ] Example `hooks.json` snippet for PreToolUse
- [ ] Example `scope-protection.sh` script
- [ ] Example scope file JSON structure

## Review Log

### 2026-02-16 — Two-stage design review (parallel: haiku + sonnet)

**Stage 1: Spec Completeness — Issues Found**

Critical (agreed by both models):
1. Hook script interface unspecified → **Fixed:** added "Hook Script Interface" section with input/output/env var docs
2. YAML parsing in shell infeasible → **Fixed:** scripts use `grep` on flat keys, no YAML parser needed
3. SessionStart broken frontmatter parsing → **Fixed:** `get_plan_title` finds `# ` heading, not first line
4. `stop_hook_active` mechanism ambiguous → **Fixed:** documented as Claude Code-provided field in input JSON

Important (agreed or sonnet-only):
5. Multiple active plans → **Fixed:** active plan tracking via `.claude/orchestrator-state.json`
6. TaskCompleted context missing → **Fixed:** plan path from state file, task metadata contract defined
7. PreCompact underspecified → **Fixed:** added concrete example script and preserved state definition
8. Config validation missing → **Fixed:** added validation rules table
9. TaskCompleted fires for non-implementation tasks → **Fixed:** scope check via orchestrator-state.json existence
10. Implementation tasks lack acceptance criteria → **Fixed:** added per-task acceptance criteria
11. Worktree paths not preserved → **Fixed:** SessionStart checks for worktree section in design doc

**Stage 2: Feasibility — Conditional Pass**

Critical (agreed by both models):
1. grep portability (BSD vs GNU) → **Fixed:** all scripts use `grep -E`, common.sh enforces this
2. `jq` dependency undocumented → **Fixed:** documented in dependencies, `check_deps` exits 0 if missing

Important (agreed or sonnet-only):
3. Timeouts unspecified → **Fixed:** 5s for command hooks, 10s for task-completed dispatcher, 120s for agent
4. Performance impact undocumented → **Fixed:** added performance section to TaskCompleted
5. No active plan tracking → **Fixed:** orchestrator-state.json (same fix as completeness #5)
6. Race conditions on design doc → **Accepted:** hooks are read-only on design doc. All writes go through implement command. Read-during-write produces stale data at worst, not corruption.
7. Missing env var checks → **Fixed:** `hook_init` checks `$CLAUDE_PROJECT_DIR`, exits 0 if missing

### 2026-02-16 — Re-review after fixes (parallel: haiku + sonnet)

**Stage 1: Spec Completeness — Conditional Pass**

Agreed (both models):
1. TaskCompleted dispatch mechanism still unvalidated → **Fixed:** added "Pre-Implementation Validation" section making Task 1 a hard blocker
2. orchestrator-state.json write timing ambiguous → **Fixed:** specified "BEFORE TeamCreate", atomic writes, cleanup on failure
3. Implementer TaskUpdate metadata timing unclear → **Fixed:** documented ordering (TaskUpdate BEFORE SendMessage), added failure modes

Sonnet-only:
4. SessionStart overlaps PreCompact on `compact` source → **Fixed:** removed `compact` from SessionStart matcher
5. Worktree field structure needs examples → **Fixed:** added polyrepo/monorepo/none examples to state file spec

**Stage 2: Feasibility — Pass**

Agreed (both models):
1. Design is feasible — scripts portable, race conditions acceptable, failure modes well-handled ✓
2. TaskCompleted dispatch is only blocking unknown — design works either way with Plan B ✓
3. All 10 tasks implementable ✓

Sonnet-only:
4. Use `jq -n --arg` for JSON construction → **Fixed:** all scripts updated
5. Atomic writes for orchestrator-state.json → **Fixed:** added to Task 7 acceptance criteria
6. Add `$CLAUDE_PLUGIN_ROOT` check to `hook_init` → **Fixed:** added to common.sh
7. `get_plan_title` should fall back to filename → **Fixed:** added fallback
8. Stop hook second attempt should re-count → **Fixed:** re-counts incomplete tasks on force-stop
