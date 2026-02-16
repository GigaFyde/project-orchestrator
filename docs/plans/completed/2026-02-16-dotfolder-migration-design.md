# Move Orchestrator State to `.project-orchestrator/`

**Status:** complete
**Created:** 2026-02-16
**Slug:** dotfolder-migration

## Problem

The plugin stores runtime state files in `.claude/` alongside Claude Code's own configuration. This causes confusion — it looks like Claude settings are being modified when only orchestrator state is changing. The `.claude/` directory should be reserved for Claude Code's own files (`project.yml`, `settings.json`, hooks config).

## Design

### Feature Type
Configuration/infra (plugin improvement)

### Services Affected
- project-orchestrator (this plugin — no external services)

### Design Details

#### Migration Map

| Current Path | New Path | Purpose |
|-------------|----------|---------|
| `.claude/orchestrator-state.json` | `.project-orchestrator/state.json` | Active plan tracker |
| `.claude/orchestrator-state.json.tmp` | `.project-orchestrator/state.json.tmp` | Atomic write temp file |
| `.claude/review-analytics.json` | `.project-orchestrator/review-analytics.json` | Review analytics |
| `.claude/hooks/scopes/{team}.json` | `.project-orchestrator/scopes/{team}.json` | Scope files for auto-approve |
| `.claude/agent-memory/project-orchestrator-{type}/` | `.project-orchestrator/agent-memory/{type}/` | Reviewer memory |

**Stays in `.claude/`:** `project.yml` (Claude Code convention — we read it, don't own it).

#### Changes by File

**Commands (3 files):**
- `commands/implement.md` — update state file path (steps 6, 6a, 6b, 10), scope file path (step 6b), analytics path (success criteria)
- `commands/progress.md` — update analytics path (steps 8, 5 fallback, success criteria)
- `commands/review.md` — update analytics path (step 9, success criteria)

**Agents (2 files):**
- `agents/spec-reviewer.md` — update memory directory path
- `agents/quality-reviewer.md` — update memory directory path

**Scripts (2 files):**
- `scripts/lib/common.sh` — update `get_active_plan()` to read from new path
- `scripts/precompact-state.sh` — update state file path

**Examples (2 files):**
- `examples/hooks/scope-protection/scope-protection.sh` — update state file and scope file paths
- `examples/hooks/scope-protection/README.md` — update paths in docs and examples

**Documentation (1 file):**
- `README.md` — update scope file path, agent memory path, analytics path references

**Active design docs (2 files):**
- `docs/plans/2026-02-16-orchestrator-implementation-fixes-design.md` — update state file and scope paths
- `docs/plans/2026-02-16-mcp-server-design.md` — update scope file path references

**Completed design docs:** NOT updated — they're historical records of decisions made at the time.

#### Script Coverage Note

Other hook scripts (`task-completed.sh`, `stop-guard.sh`, `session-context.sh`) call `get_active_plan()` from `common.sh` — they don't hardcode paths directly. Updating `common.sh` covers all callers automatically. Reviewer skill files (`skills/spec-reviewer/SKILL.md`, `skills/quality-reviewer/SKILL.md`) don't reference memory paths — only the agent definitions do.

#### Directory Creation

Commands and scripts that write to `.project-orchestrator/` must ensure the directory exists via `mkdir -p` before each write. Same for subdirectories (`scopes/`, `agent-memory/{type}/`). No separate init step — each command is responsible for its own subdirs.

#### `.gitignore`

Consumer projects should add `.project-orchestrator/` to `.gitignore` — it contains session-specific state, not checked-in config. The plugin's README should recommend this in the setup section.

#### Existing Agent Memory

Clean break — old memory at `.claude/agent-memory/project-orchestrator-{type}/` is not auto-migrated. Reviewers start fresh with the new path. If a consumer wants to preserve accumulated memory, they can manually `cp -r .claude/agent-memory/project-orchestrator-spec-reviewer/ .project-orchestrator/agent-memory/spec-reviewer/` (and same for quality-reviewer).

#### Breaking Change for Consumer Hooks

Consumers who copied `examples/hooks/scope-protection/` into their projects will need to update their copies after this change. The example hook paths change from `.claude/orchestrator-state.json` and `.claude/hooks/scopes/` to `.project-orchestrator/state.json` and `.project-orchestrator/scopes/`. Note this in the plugin's changelog/release notes.

#### Backward Compatibility

None needed beyond the notes above. This is a plugin that generates instructions for AI agents — there's no running code to maintain backward compat with. Once the paths are updated, all new sessions use the new paths. Old `.claude/` state files from previous sessions can be manually deleted.

#### What Stays in `.claude/`

Only `project.yml` (Claude Code convention). The hooks infrastructure (`hooks/hooks.json`, hook scripts) lives in the plugin directory via `${CLAUDE_PLUGIN_ROOT}`, not in `.claude/`. Only the data files hooks read/write (state, scopes) migrate to `.project-orchestrator/`.

## Implementation Tasks

| # | Task | Files | Status | Assignee | Spec | Quality | Fix Iterations |
|---|------|-------|--------|----------|------|---------|----------------|
| 1 | Update commands (implement, progress, review) | `commands/implement.md`, `commands/progress.md`, `commands/review.md` | complete | implement-commands | pass | pass | 0 |
| 2 | Update agents and README | `agents/spec-reviewer.md`, `agents/quality-reviewer.md`, `README.md` | complete | implement-agents | pass | pass | 0 |
| 3 | Update scripts and examples | `scripts/lib/common.sh`, `scripts/precompact-state.sh`, `examples/hooks/scope-protection/scope-protection.sh`, `examples/hooks/scope-protection/README.md` | complete | implement-scripts | pass | pass | 0 |
| 4 | Update active design docs | `docs/plans/2026-02-16-orchestrator-implementation-fixes-design.md`, `docs/plans/2026-02-16-mcp-server-design.md` | complete | implement-docs | pass | pass | 0 |

**Wave plan:** All 4 tasks target different files — single wave, all parallel.

## Decisions & Context

- **`.project-orchestrator/` chosen over alternatives** — `.orchestrator/` is too generic, `.po/` is too cryptic. `.project-orchestrator/` matches the plugin name and is unambiguous.
- **Shorter state file name** — `orchestrator-state.json` → `state.json` since the directory already namespaces it.
- **Shorter agent memory path** — `.claude/agent-memory/project-orchestrator-{type}/` → `.project-orchestrator/agent-memory/{type}/` drops the redundant `project-orchestrator-` prefix.
- **No backward compat** — plugin is markdown instructions, not running code. Clean break is simplest.
- **Completed design docs untouched** — historical accuracy preserved. This design doc documents the migration.
