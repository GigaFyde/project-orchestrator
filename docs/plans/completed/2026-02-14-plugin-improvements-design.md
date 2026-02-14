# project-orchestrator Plugin Improvements — Design & Implementation

## Status: complete

## Design

### Feature Type
Configuration/infra + skill refinement

### Services Affected
- `~/project-orchestrator/` (plugin repo — not a Toraka service)

### Design Details

#### Problem
Plugin v1.0 was extracted from Toraka-specific tooling. Several bugs and gaps need fixing before it's robust for general use.

#### Bug Fixes (all in `~/project-orchestrator/`)

**B1. implement.md references wrong skill**
- File: `commands/implement.md` line 6
- Bug: `skills: [project-orchestrator:brainstorming]` — loads brainstorm skill into implement context. Copy-paste error from brainstorm.md. The implement command never invokes the brainstorming skill in its process — review stages reference their own skills at spawn time.
- Fix: Remove line 6 (`skills: [project-orchestrator:brainstorming]`) from frontmatter.

**B2. Non-existent MCP tool references**
- Files: `skills/finishing-branch/SKILL.md`, `skills/verification/SKILL.md`, `skills/implementer/SKILL.md`
- Bug: Reference `repo_status()`, `verify_workspace()`, `check_file_conflicts()` — none exist as real MCP tools
- Fix: Remove all references to non-existent tools. Keep only tools that actually exist: `list_branches()`, `list_features()`, `feature_progress()`, `create_scope()`, `delete_scope()`, `report_activity()`, `save_state()`, `load_state()`. For workspace verification, use manual git commands as the primary path (not fallback).
- Affected tools to KEEP (exist in toraka-dev-local): `list_branches`, `list_features`, `feature_progress`, `update_feature`, `create_scope`, `delete_scope`, `report_activity`, `save_state`, `load_state`, `acquire_lock`, `release_lock`, `delete_state`, `agent_handoff`, `receive_handoff`
- Affected tools to REMOVE references to: `repo_status`, `verify_workspace`, `check_file_conflicts`

**B3. Review command tells subagents to "invoke skill"**
- File: `commands/review.md` lines 33-45
- Bug: Current wording says "Read `.claude/skills/...` or invoke `project-orchestrator:spec-reviewer` skill" — the "invoke" option fails for subagents (Skill tool is main-session only), and the Read path points to `.claude/skills/` which is wrong for a plugin (skills live in the plugin dir)
- Fix: Remove the "or invoke" option entirely. Use absolute path: `Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md` and `Read ~/project-orchestrator/skills/quality-reviewer/SKILL.md`

**B4. Brainstorm skill dead Phase 2 section**
- File: `skills/brainstorming/SKILL.md` lines 239-270 (entire Phase 2 section through section break)
- Bug: ~30 lines of "reference only" implementation details for Phase 2 that duplicate `/project:implement`
- Fix: Remove lines 239-270 (from `# Phase 2: Implementation` through the `---` section break). Replace with: `**Implementation is handled by \`/project:implement\`. See that command for details.**`

#### Enhancements

**E1. Parallel model review (from existing design doc)**
Incorporate the parallel Haiku+Sonnet review pattern into `/project:review`.

Current flow (single model):
```
Spec review (opus) → Quality review (opus) → done
```

New flow (parallel multi-model, when `review.strategy: parallel`):
```
Per unreviewed task:
  Stage 1 — Spec compliance:
    Spawn reviewer A (model: config.review.parallel_models[0], e.g. haiku)
    Spawn reviewer B (model: config.review.parallel_models[1], e.g. sonnet)
    → Both run in parallel via Task tool
    → /project:review command (lead session) merges findings

  Stage 2 — Quality (only if spec passes):
    Same parallel spawn + merge pattern

  Present merged report per task
```

**Merge actor:** The `/project:review` command itself (lead session) does the merge — NOT a separate agent. It reads both reviewer outputs and categorizes findings into the table below.

Merge strategy:
| Category | Meaning | Action |
|----------|---------|--------|
| Agreed | Both models flagged | High confidence — must address |
| Model-B-only | Only the stronger model found it | Likely real — review and usually apply |
| Model-A-only | Only the faster model found it | Often structural/organizational — review, may be stylistic |
| Contradictions | Models disagree | Present both arguments, human decides |

**Validation:** `review.parallel_models` must contain exactly 2 entries. If fewer or more, error with message: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])".

Cost: Comparable to single Opus review, but catches more bugs via model diversity. Two cheaper models in parallel provide better coverage than one expensive model.

**E2. Full configurability via project.yml**

New `project.yml` schema extension — top-level siblings for each concern:

```yaml
# .claude/project.yml — new config sections (all optional, sensible defaults)

# Existing section — unchanged
implementation:
  auto_review: true        # default: true
  max_parallel: 3          # default: 3

# NEW: Model assignments per role
models:
  explorer: sonnet         # default: sonnet (cheap read-only exploration)
  implementer: opus        # default: opus (needs highest quality for code generation)

# NEW: Review configuration
review:
  strategy: parallel       # parallel | single — default: parallel
  # When strategy=parallel, spawn two reviewers with these models:
  parallel_models: [haiku, sonnet]  # default: [haiku, sonnet] — must be exactly 2
  # When strategy=single, use this model for both spec + quality:
  single_model: opus       # default: opus

# NEW: Brainstorm behavior
brainstorm:
  default_depth: medium    # shallow | medium | deep — default: medium
  team_threshold: 3        # auto-team when >= N services affected — default: 3
  designer_perspectives: [simplicity, scalability]  # default: [simplicity, scalability] — supports custom names (e.g., security, performance)
  # Optional: map custom perspective names to doc files for prompt injection
  # If a perspective has no entry here, it's spawned with name only (no doc injection)
  perspective_docs:                                  # default: {} (empty map)
    # example: reactive-safety: toraka-core/CLAUDE.md#reactive-safety-rules
```

**Model precedence rules:**
- When `review.strategy: parallel` → use `review.parallel_models` for both spec and quality reviewers (spawn 2 per stage)
- When `review.strategy: single` → use `review.single_model` for both spec and quality reviewers (spawn 1 per stage)
- `models.explorer` → always used when spawning explorer agents
- `models.implementer` → always used when spawning implementer agents
- Review model config is separate from role models — `models.*` does NOT contain reviewer entries (reviewers are controlled by `review.*`)

Defaults (when key is missing):

| Key | Default | Rationale |
|-----|---------|-----------|
| `implementation.auto_review` | `true` | Review by default |
| `implementation.max_parallel` | `3` | Current behavior |
| `models.explorer` | `sonnet` | Read-only, cost-effective |
| `models.implementer` | `opus` | Code generation needs highest quality |
| `review.strategy` | `parallel` | More coverage via model diversity |
| `review.parallel_models` | `[haiku, sonnet]` | Diversity catches more bugs |
| `review.single_model` | `opus` | When parallel is overkill |
| `brainstorm.default_depth` | `medium` | Safe middle ground |
| `brainstorm.team_threshold` | `3` | Current behavior |
| `brainstorm.designer_perspectives` | `[simplicity, scalability]` | Supports custom names (e.g., `[security, performance]`) |
| `brainstorm.perspective_docs` | `{}` (empty map) | Optional doc injection for custom perspectives |

**Config validation:**
| Rule | Error |
|------|-------|
| `review.parallel_models` not exactly 2 entries | "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])" |
| `review.strategy` not `parallel` or `single` | "review.strategy must be 'parallel' or 'single'" |
| `brainstorm.default_depth` not `shallow`/`medium`/`deep` | "brainstorm.default_depth must be 'shallow', 'medium', or 'deep'" |
| `models.*` value not `opus`/`sonnet`/`haiku` | "Model must be 'opus', 'sonnet', or 'haiku'" |
| `brainstorm.perspective_docs` key not in `designer_perspectives` | Warning (not error): "perspective_docs key '{name}' not found in designer_perspectives — will be ignored" |

**Where config is consumed:**

| Config key | Consumed by | How |
|------------|-------------|-----|
| `models.explorer` | `skills/brainstorming/SKILL.md` | Read project.yml, pass `model:` to Task tool when spawning explorers |
| `models.implementer` | `commands/implement.md` | Read project.yml, pass `model:` to Task tool when spawning implementers |
| `review.strategy` | `commands/review.md`, `commands/implement.md` (auto-review) | Determines single vs parallel flow |
| `review.parallel_models` | `commands/review.md`, `commands/implement.md` | Which 2 models to spawn in parallel mode |
| `review.single_model` | `commands/review.md`, `commands/implement.md` | Which model for single mode |
| `brainstorm.default_depth` | `skills/brainstorming/SKILL.md` | Pre-selects exploration depth (user can still override) |
| `brainstorm.team_threshold` | `skills/brainstorming/SKILL.md` | When to create brainstorm team vs simple agents |
| `brainstorm.designer_perspectives` | `skills/brainstorming/SKILL.md` | Which perspectives to spawn in multi-perspective design |
| `brainstorm.perspective_docs` | `skills/brainstorming/SKILL.md` | When spawning a custom perspective, read the mapped file and inject its content into the designer agent's prompt. If no entry exists for a perspective, spawn with name only (no doc injection — not an error). |

**How config is consumed at spawn time:**

Commands/skills read `project.yml` early in their process, then pass the model when calling the Task tool:
```
# Example in /project:implement
config = read(".claude/project.yml")
model = config.models.implementer ?? "opus"

Task(subagent_type: "implementer", model: model, team_name: "implement-{slug}", ...)
```

Agent `.md` files keep static `model:` defaults in frontmatter — these are used when spawned without config (e.g., ad-hoc exploration). The Task tool's `model:` parameter overrides agent frontmatter when provided.

**E3. Reviewer agents — promote from ad-hoc spawns to proper agent definitions**

Currently, reviewers are spawned as generic `general-purpose` or `feature-dev:code-reviewer` agents with skill content pasted into the prompt. This wastes tokens and prevents reviewer-specific features.

Create two new agent files:

**`agents/spec-reviewer.md`:**
```yaml
---
name: spec-reviewer
description: "Reviews implementation against task specification. Checks for missing requirements, extras, and misunderstandings."
model: sonnet
memory: project
---
```
- Body: Extract review instructions from `skills/spec-reviewer/SKILL.md` into the agent definition
- Agent reads the skill on its own via `Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md`
- `memory: project` allows reviewer to learn project-specific patterns across reviews

**`agents/quality-reviewer.md`:**
```yaml
---
name: quality-reviewer
description: "Reviews code quality after spec compliance passes. Focuses on clean code, test coverage, security, and project patterns."
model: sonnet
memory: project
---
```
- Same pattern — body references the skill file

**Both agents must include these first steps in their body:**
```
## First Steps
1. Read `.claude/project.yml` for project config
2. Read architecture docs if configured (config.architecture_docs.agent, config.architecture_docs.domain)
3. Read target service's CLAUDE.md for stack-specific patterns — use its rules as review criteria in addition to generic quality checks
```

**Benefits:**
- Commands spawn `subagent_type: "spec-reviewer"` or `"quality-reviewer"` instead of `general-purpose` with pasted instructions
- Model controlled via `model:` frontmatter default + Task tool `model:` override from config
- Shared project memory — reviewer learns which patterns to flag across reviews
- Cleaner spawn prompts — just pass the task context, not the full skill content

**Config consumption change:**
- In parallel mode: spawn each reviewer agent twice with different models from `review.parallel_models`
- In single mode: spawn once with `review.single_model`
- Example: `Task(subagent_type: "spec-reviewer", model: "haiku", ...)` and `Task(subagent_type: "spec-reviewer", model: "sonnet", ...)`

**E4. Implementer skill — clean up MCP section**
- File: `skills/implementer/SKILL.md` lines 124-158
- After Task 2 removes `repo_status()` and `verify_workspace()` references, the surviving MCP calls are: `acquire_lock`, `release_lock`, `save_state`, `load_state`, `delete_state`, `report_activity`
- Fix: Add "If MCP unavailable or call fails, skip — optional resilience feature" to each surviving MCP call in lines 127-157. Currently only `save_state` (line 148) has this caveat.
- Specific locations needing the caveat: `acquire_lock` (line 132), `report_activity` (lines 134, 152, 157), `release_lock` (lines 151, 156), `delete_state` (line 153)

**E5. Update README.md with new config schema**
- File: `README.md`
- Add new top-level config sections (`models:`, `review:`, `brainstorm:`) to the Full Schema section (after existing `implementation:` block, around line 69)
- Add new agents (`spec-reviewer`, `quality-reviewer`) to Agents table
- Add defaults table after Config Validation section (after line 83)
- Document validation rules

## Implementation Tasks

| # | Task | Status | Assignee | Spec | Quality |
|---|------|--------|----------|------|---------|
| 1 | Fix implement.md wrong skill reference (B1) | complete | implement-b1 | ✅ | ✅ |
| 2 | Remove non-existent MCP tool references from finishing-branch, verification, implementer skills (B2) | complete | implement-b2 | ✅ | ✅ |
| 3 | Fix review.md subagent skill invocation — use Read instead of Skill tool (B3) | complete | implement-b3 | ✅ | ✅ |
| 4 | Remove brainstorm skill dead Phase 2 section (B4) | complete | implement-b4 | ✅ | ✅ |
| 5 | Add parallel model review to review command + update review flow (E1) | complete | implement-e1 | ✅ | ✅ |
| 6 | Create spec-reviewer and quality-reviewer agent definitions (E3) | complete | implement-e3 | ✅ | ✅ |
| 7 | Add config schema for models, review strategy, brainstorm behavior (E2) — update brainstorm skill, implement command, review command to read config | complete | implement-e2 | ✅ | ✅ |
| 8 | Clean up implementer skill MCP section — add graceful failure notes (E4) | complete | implement-e4 | ✅ | ✅ |
| 9 | Update README.md with new config schema, agents, and defaults (E5) | complete | implement-e5 | ✅ | ✅ |

### Dependencies
- Tasks 1-4: independent (parallel wave 1)
- Task 5: depends on Task 3 (review.md base changes)
- Task 6: independent (new files only — `agents/spec-reviewer.md`, `agents/quality-reviewer.md`)
- Task 7: depends on Tasks 1, 4, 5, 6 (implement.md from T1, brainstorming from T4, review.md from T5, reviewer agents from T6)
- Task 8: depends on Task 2 (implementer skill — T2 removes dead refs, T8 adds failure notes to survivors)
- Task 9: depends on Tasks 5, 6, 7 (needs final config schema, agents, and review flow)

### Shared file analysis
- `commands/review.md`: Tasks 3, 5, 7 — **sequence** (3 → 5 → 7)
- `commands/implement.md`: Tasks 1, 7 — **sequence** (1 → 7)
- `skills/brainstorming/SKILL.md`: Tasks 4, 7 — **sequence** (4 → 7)
- `skills/implementer/SKILL.md`: Tasks 2, 8 — **sequence** (2 → 8)
- `agents/spec-reviewer.md`: Task 6 only — **no conflict** (new file)
- `agents/quality-reviewer.md`: Task 6 only — **no conflict** (new file)

### Suggested waves
- **Wave 1:** Tasks 1, 3, 4, 6 (bug fixes + new agent files — no shared files)
- **Wave 2:** Tasks 2, 5 (T2: implementer MCP cleanup, T5: parallel review in review.md — no shared files)
- **Wave 3:** Tasks 7, 8 (T7: config schema across brainstorm+implement+review, T8: implementer graceful failure — no shared files)
- **Wave 4:** Task 9 (README — needs all changes finalized)

## Decisions & Context

- Explorer default stays Sonnet — Opus only when configured via project.yml
- Parallel review uses Haiku+Sonnet by default — catches more bugs via model diversity
- Reviewers promoted to proper agents (`spec-reviewer`, `quality-reviewer`) with `memory: project` for cross-review learning
- MCP tools that don't exist get removed entirely, not "fallback" — you can't fall back from fiction
- Plugin root path: `~/project-orchestrator/` for absolute paths in skill Read instructions
- All changes are to the plugin repo at `~/project-orchestrator/`, not Toraka services
- Config is additive — all new keys have sensible defaults, zero-config mode still works
- Agent `.md` files keep static `model:` defaults — config override happens at spawn time in commands/skills
- Config schema is flat (top-level siblings: `models`, `review`, `brainstorm`) — NOT nested under `implementation`
- Review model precedence: `review.strategy` + `review.parallel_models`/`review.single_model` control reviewer models. `models.*` only controls explorer and implementer.
- Merge actor for parallel review: `/project:review` command (lead session), not a separate agent
- `review.parallel_models` validated to exactly 2 entries
- Plugin now has 4 agents (explorer, implementer, spec-reviewer, quality-reviewer) — up from 2
