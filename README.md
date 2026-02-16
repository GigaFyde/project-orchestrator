# project-orchestrator

Full-lifecycle project orchestration plugin for Claude Code. Turns feature ideas into designs and implementations using parallel teams, two-stage review, and living state documents.

## Installation

Run this inside Claude Code to add the marketplace and install the plugin:

```
/plugin marketplace add gigafyde/project-orchestrator
/plugin install project-orchestrator@project-orchestrator
```

**Private repo note:** This requires access to the GitHub repo. Your existing git credentials (e.g., `gh auth login`) are used automatically. For background auto-updates, set `GITHUB_TOKEN` or `GH_TOKEN` in your environment.

(Optional) Create `.project-orchestrator/project.yml` in your project to customize behavior — see [Project Config](#project-config) below. The plugin works without any config using sensible defaults.

**Breaking change:** If you have an existing `.claude/project.yml` from a previous version, you must move it to `.project-orchestrator/project.yml`. The config file has moved as part of completing the dotfolder migration.

**Recommended:** Add `.project-orchestrator/` to your `.gitignore` — it contains session-specific state (active plan tracker, scope files, review analytics, agent memory) that shouldn't be committed.

## Commands

| Command | Purpose |
|---------|---------|
| `/project:brainstorm` | Design phase — brainstorm and create a design document |
| `/project:implement` | Implementation phase — spawn parallel workers from a design doc |
| `/project:review` | Two-stage review — spec compliance + code quality |
| `/project:verify` | Evidence-based verification before claiming completion |
| `/project:finish` | Branch finishing — merge, PR, or keep |
| `/project:progress` | Check feature status and suggest next steps |
| `/project:changelog` | Add standardized changelog entries |

## Project Config

Create `.project-orchestrator/project.yml` in your project root. All fields are optional — the plugin uses sensible defaults when config is missing.

### Full Schema

```yaml
# .claude/project.yml
name: my-project

# Repo structure
structure: polyrepo          # polyrepo | monorepo (default: monorepo)
plans_dir: docs/plans        # where design docs live (default: docs/plans)
plans_structure: standard    # standard (subdirs: completed/backlog/ideas + INDEX.md) | flat (default: flat)

# Architecture docs (optional — skills use these for context)
architecture_docs:
  agent: docs/ARCHITECTURE-AGENT.md
  human: docs/ARCHITECTURE.md
  domain: docs/DOMAIN-GUIDE.md

# Services (for multi-service projects)
services:
  - name: api
    path: api/
    branch: main             # default: main
    remote: true             # has git remote? (default: true)
    test: ./gradlew test     # test command (auto-detected if omitted)
    changelog: api/CHANGELOG.md  # changelog path (skip if omitted)
    auto_deploy: true        # warn before push? (default: false)
  - name: frontend
    path: frontend/
    branch: main
    remote: true
    test: pnpm test
    changelog: frontend/CHANGELOG.md
    auto_deploy: true

# Implementation behavior
implementation:
  auto_review: true          # --no-review flag overrides (default: true)
  max_parallel: 3            # max parallel implementer agents (default: 3)

# Model assignments per role
models:
  explorer: sonnet           # default: sonnet (read-only exploration)
  implementer: opus          # default: opus (code generation)

# Review configuration
review:
  strategy: parallel         # parallel | single (default: parallel)
  parallel_models: [haiku, sonnet]  # 2 models for parallel review (default: [haiku, sonnet])
  single_model: opus         # model for single review (default: opus)

  # Review System v2
  speculative_quality: true  # run quality in parallel with spec on first review (default: true)
  max_fix_iterations: 2      # max fix attempts before human escalation (default: 2, valid: 1-5)
  fix_timeout_turns: 10      # max agent turns per fix attempt (default: 10, valid: 5-30)
  auto_approve: false        # auto-approve high-confidence passes (default: false)
  auto_reject: false         # auto-send-to-implementer high-confidence failures (default: false)

# Brainstorm behavior
brainstorm:
  default_depth: medium      # shallow | medium | deep (default: medium)
  team_threshold: 3          # auto-team when >= N services (default: 3)
  designer_perspectives: [simplicity, scalability]  # default perspectives
  perspective_docs:          # optional: map perspective names to doc files
    # reactive-safety: path/to/doc.md
```

### Config Validation

| Condition | Behavior |
|-----------|----------|
| Missing `.project-orchestrator/project.yml` | Defaults: monorepo, single service at root, auto-detect test command |
| Malformed YAML | Hard error — fix config before proceeding |
| Missing referenced file (architecture doc, plans dir) | Warn once, skip that step. Auto-create `plans_dir` on first brainstorm |
| Invalid service path | Error when that service is targeted by a task |
| Missing `test` for a service | Auto-detect from package.json / build.gradle / Makefile, or skip tests |
| Missing `changelog` for a service | Skip changelog step for that service |
| Missing `branch` for a service | Default to `main` |
| Missing `remote` for a service | Default to `true` |
| `review.parallel_models` not exactly 2 entries | Error: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])" |
| `review.strategy` not `parallel` or `single` | Error: "review.strategy must be 'parallel' or 'single'" |
| `brainstorm.default_depth` not `shallow`/`medium`/`deep` | Error: "brainstorm.default_depth must be 'shallow', 'medium', or 'deep'" |
| `models.*` not `opus`/`sonnet`/`haiku` | Error: "Model must be 'opus', 'sonnet', or 'haiku'" |
| `review.max_fix_iterations` not 1-5 | Error: "max_fix_iterations must be 1-5" |
| `review.fix_timeout_turns` not 5-30 | Error: "fix_timeout_turns must be 5-30" |
| `brainstorm.perspective_docs` key not in `designer_perspectives` | Warning (not error): key will be ignored |

### Defaults

| Key | Default | Rationale |
|-----|---------|-----------|
| `implementation.auto_review` | `true` | Review by default |
| `implementation.max_parallel` | `3` | Reasonable parallelism |
| `models.explorer` | `sonnet` | Read-only, cost-effective |
| `models.implementer` | `opus` | Code generation needs highest quality |
| `review.strategy` | `parallel` | Model diversity catches more bugs |
| `review.parallel_models` | `[haiku, sonnet]` | Fast + thorough combination |
| `review.single_model` | `opus` | Best single model for reviews |
| `review.speculative_quality` | `true` | Saves one review cycle on passing tasks |
| `review.max_fix_iterations` | `2` | Enough for quick fixes, escalates real issues |
| `review.fix_timeout_turns` | `10` | Prevents infinite agent loops |
| `review.auto_approve` | `false` | Conservative — human reviews all until confidence builds |
| `review.auto_reject` | `false` | Conservative — human confirms before sending back |
| `brainstorm.default_depth` | `medium` | Safe middle ground |
| `brainstorm.team_threshold` | `3` | Teams for 3+ services |
| `brainstorm.designer_perspectives` | `[simplicity, scalability]` | Balanced design trade-offs |
| `brainstorm.perspective_docs` | `{}` (empty) | Optional doc injection |

### Model Precedence

- `models.explorer` → used when spawning explorer agents
- `models.implementer` → used when spawning implementer agents
- `review.strategy` + `review.parallel_models` / `review.single_model` → controls reviewer models
- Review config is separate from role models — `models.*` does NOT control reviewers
- Agent `.md` files have static `model:` defaults in frontmatter — the Task tool's `model:` parameter overrides when provided via config

### No Config (Zero-Config Mode)

Without `project.yml`, the plugin assumes:
- **Structure:** monorepo, single service at root
- **Plans dir:** `docs/plans/`, flat structure
- **Architecture docs:** none (skills skip context loading)
- **Test command:** auto-detected from package.json / build.gradle / Makefile
- **Changelog:** none (skip changelog step)

## Plugin Hooks

The plugin ships 4 opt-in hooks that improve orchestration quality during `/project:implement` sessions. **No hooks fire unless explicitly enabled** — missing config, missing dependencies (`jq`), or missing environment variables all result in silent no-ops.

### Configuration

Enable hooks in `.project-orchestrator/project.yml`:

```yaml
# .claude/project.yml
hooks:
  task_verification: "agent"    # "agent" | "prompt" | "off" (default: off)
  stop_guard: true              # default: false
  session_context: true         # default: false
  precompact_state: true        # default: false
```

| Key | Values | Default |
|-----|--------|---------|
| `hooks.task_verification` | `"agent"`, `"prompt"`, `"off"` | `"off"` |
| `hooks.stop_guard` | `true`, `false` | `false` |
| `hooks.session_context` | `true`, `false` | `false` |
| `hooks.precompact_state` | `true`, `false` | `false` |

### Shipped Hooks

#### TaskCompleted — Deliverable Verification

Verifies that completed tasks actually match their spec in the design doc before accepting completion. Only fires during active `/project:implement` sessions.

- **`"agent"` mode** — injects thorough verification context: checks files exist, commits were made, and spec requirements are met. Adds **30–120s per task**.
- **`"prompt"` mode** — lightweight format check: confirms commit SHA, file list, and test results are present. Adds ~5s per task.
- **When to enable:** Recommended for projects where spec compliance matters. Use `"agent"` for thoroughness, `"prompt"` for speed.

#### Stop — Prevent Premature Session End

Blocks the lead agent from stopping while implementation tasks are still in-progress or pending. On second stop attempt, allows it with a warning that running implementers will continue without coordination.

- **When to enable:** Recommended for long-running parallel implementations where accidental stops are costly.

#### SessionStart — Auto-Load Context After `/clear`

After `/clear` or session resume, injects a summary of the active implementation: plan name, task progress, worktree paths, and blocked/escalated tasks. Fires on `clear` and `resume` only (not `compact` — PreCompact handles that).

- **When to enable:** Recommended if you use `/clear` during implementation sessions.

#### PreCompact — Preserve State Across Compaction

Before automatic context compaction, injects orchestration state (plan, team, progress) so the summarizer preserves it. Complements SessionStart — one handles `/clear`, the other handles compaction.

- **When to enable:** Recommended for large implementations that may trigger context compaction.

### Performance

| Hook | Overhead |
|------|----------|
| TaskCompleted (`"agent"`) | 30–120s per task completion |
| TaskCompleted (`"prompt"`) | ~5s per task completion |
| Stop guard | <1s |
| SessionStart context | <1s |
| PreCompact state | <1s |

For a 6-task implementation with 3 parallel workers, agent-mode verification adds roughly 3–12 minutes total.

### Scope Protection (Example)

The plugin includes a reference implementation for file-scope enforcement via PreToolUse hooks. This is shipped as a **template** in [`examples/hooks/scope-protection/`](examples/hooks/scope-protection/), not as a built-in hook — scope management varies across projects.

See the example README for setup instructions, scope file format, and `hooks.json` snippet.

## Config Loading

Every skill/command begins with:

1. Check if `.project-orchestrator/project.yml` exists
2. If yes: parse, validate, extract services/paths/test commands
3. If no: use defaults (monorepo, root, auto-detect)
4. Check for architecture docs: read if present
5. Ensure `plans_dir` exists (create if missing on write operations)
6. Proceed with project-aware context

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| `implementer` | Implements tasks from design docs | `config.models.implementer` (default: opus) |
| `explorer` | Read-only codebase exploration | `config.models.explorer` (default: sonnet) |
| `spec-reviewer` | Reviews implementation against task spec | Per `config.review.strategy` |
| `quality-reviewer` | Reviews code quality after spec passes | Per `config.review.strategy` |

## Lifecycle Flow

```
/project:brainstorm → design doc created
    ↓
/project:implement → parallel workers, optional auto-review
    ↓
/project:review → two-stage review (spec + quality)
    ↓
/project:verify → evidence-based verification
    ↓
/project:finish → merge/PR/keep
    ↓
/project:changelog → standardized entries
```

## Coexistence with Superpowers

This plugin coexists with the `superpowers` plugin:
- **Different prefixes:** `/project:brainstorm` vs `/brainstorm`
- **Different skill names:** `project-orchestrator:brainstorming` vs `superpowers:brainstorming`
- **Use superpowers** for simple, single-file features
- **Use project-orchestrator** for multi-service orchestration with teams

## Auto-Approve Integration

For projects that use permission hooks (auto-approve systems), the `implement` command supports optional scope file creation via MCP tools. If your project has a `create_scope()` MCP tool, it will be called automatically. Otherwise, scope management is skipped gracefully.

To set up auto-approve hooks for your project, configure:
1. A PreToolUse hook that reads scope files
2. Scope files at `.project-orchestrator/scopes/{team}.json`
3. An MCP tool or manual process to create/delete scope files per implementation wave

## Review System v2

The review system includes speculative parallel execution, confidence-based auto-decisions, a fix iteration loop, review memory, and analytics tracking.

### Speculative Parallel Review

On the **first review** of each task, all reviewers run in parallel to save wall-clock time:

```
Parallel strategy (4 reviewers):
  Spec-reviewer (haiku)     ─┐
  Spec-reviewer (sonnet)    ─┤ All 4 in parallel
  Quality-reviewer (haiku)  ─┤
  Quality-reviewer (sonnet) ─┘

Single strategy (2 reviewers):
  Spec-reviewer (opus)      ─┐ Both in parallel
  Quality-reviewer (opus)   ─┘
```

After all complete, findings are merged:
1. Merge spec findings (across models) and decide spec verdict
2. If spec **passes** -- merge quality findings and decide overall verdict
3. If spec **fails** -- discard quality results (they reviewed against a non-compliant implementation)

Quality results are "speculative" because most tasks pass spec review. The cost of discarding quality results on spec failure is negligible compared to the time saved.

On **fix iterations** (2nd+ review), spec runs first (sequential), then quality only if spec passes. No speculative quality run on retries.

Control this with `review.speculative_quality` (default: `true`). Set to `false` to always run spec before quality sequentially.

### Confidence Scoring and Auto-Decisions

Each review result is assigned a confidence level based on model agreement:

| Scenario | Confidence | Auto-Action |
|----------|------------|-------------|
| Both models PASS (spec+quality), zero findings | Very High (1.0) | Auto-approve |
| Both models PASS, minor-only findings | High (0.85) | Auto-approve with notes |
| Both models FAIL, agreed critical issues | High (0.9) | Auto-reject to fix loop |
| One model PASS, one FAIL | Low (0.4) | Human decides |
| Both FAIL but disagree on which issues | Medium (0.6) | Human decides |
| Stronger model found critical issue alone | Medium (0.7) | Human decides |

Auto-decisions are controlled by two independent config keys:
- `review.auto_approve: true` -- auto-approve when both models pass with no critical/important findings
- `review.auto_reject: true` -- auto-send to implementer when both models agree on critical issues

Both default to `false` (conservative). When disabled, all results are presented to the human for decision.

### Fix Iteration Loop

When a review finds critical issues, the task enters a fix loop:

1. Review findings are sent to the implementer with specific file:line references
2. Implementer fixes the issues (bounded by `review.fix_timeout_turns` agent turns)
3. Task is re-reviewed (spec-only first, then quality if spec passes)
4. If the task passes, it is marked reviewed
5. If it fails again, repeat up to `review.max_fix_iterations` times
6. If max iterations reached, **escalate to human** -- implementation pauses for that task and dependent tasks are not started

**Task status values during the fix loop:**
- `review-fix-{N}` -- currently in fix iteration N (e.g., `review-fix-1`)
- `escalated` -- failed review after max fix attempts, waiting for human intervention

Minor-only findings (no critical or important issues) do not block -- the task is approved with notes.

### Review Memory

Reviewers maintain structured memory that improves review quality over time. Memory is stored per-service at `.project-orchestrator/agent-memory/{type}/`:

```
MEMORY.md                    # index + cross-review patterns
reviews/
  {date}-{slug}.md           # per-review findings
service-patterns/
  {service}.md               # per-service issue patterns
```

**Per-service pattern files** track:
- **Common issues** -- recurring patterns with frequency, severity, and examples
- **Service-specific rules** -- conventions learned from past reviews (e.g., "uses reactive patterns, always check schedulers")
- **False positives** -- patterns that look like issues but are valid per project conventions

**How memory is used:**
1. Before reviewing, the reviewer reads service patterns for the target service
2. Known issue patterns are weighted higher (looked for first)
3. Known false positives are skipped
4. After reviewing, patterns are updated with new findings

**Memory pruning:** Patterns not seen in 30+ days are moved to an archive section to keep active memory focused.

### Review Analytics

Review results are tracked in `.project-orchestrator/review-analytics.json` at the project root. This file is append-only and records:

```json
{
  "reviews": [
    {
      "date": "2026-02-14",
      "feature": "core-standardization",
      "task": 2,
      "service": "toraka-core",
      "strategy": "parallel",
      "models": ["haiku", "sonnet"],
      "stage": "spec",
      "haiku_verdict": "fail",
      "sonnet_verdict": "fail",
      "agreed_count": 1,
      "haiku_only_count": 0,
      "sonnet_only_count": 2,
      "confidence": 0.9,
      "auto_decision": "auto_reject",
      "human_override": null,
      "fix_iterations": 1,
      "final_verdict": "pass",
      "findings": [...]
    }
  ],
  "summary": {
    "total_reviews": 12,
    "auto_approved": 8,
    "auto_rejected": 2,
    "human_decided": 2,
    "avg_fix_iterations": 0.5,
    "model_accuracy": {
      "haiku": { "true_positive": 15, "false_positive": 3, "missed": 5 },
      "sonnet": { "true_positive": 20, "false_positive": 1, "missed": 2 }
    },
    "by_service": {
      "toraka-core": { "reviews": 6, "common_issues": ["missing subscribeOn"] }
    }
  }
}
```

**Analytics are updated:**
- After each review merge -- append review entry with findings
- After fix loop completes -- update `fix_iterations` and `final_verdict`
- After human override -- update `human_override` field
- Summary counters are recalculated on each append

**Using analytics for tuning:**
- High `model_accuracy.{model}.false_positive` -- consider switching models or strategy
- High `avg_fix_iterations` -- reviewers may be too strict, or specs need more detail
- High `common_issues` for a service -- add patterns to that service's CLAUDE.md

The `/project:progress` command includes an analytics summary when the analytics file exists.
