# project-orchestrator Plugin — Design & Implementation

> **Status:** complete
> **Category:** active
> **Service:** .claude (config/plugin development)
> **Branch:** —

## Design

### Feature Type
Infrastructure — Claude Code plugin extraction

### What This Is

Extract the 7 core Toraka lifecycle skills/commands into a reusable Claude Code plugin (`project-orchestrator`) that works with any project. Project-specific knowledge is supplied via a convention-based config file (`.claude/project.yml`).

### What This Is NOT

- Not globalizing Toraka-only skills (scraper, CLI, postgres agent, architecture audit)
- Not replacing superpowers — coexists as an enhanced layer
- Not building MCP server support (existing MCP tools like `create_scope` from project-specific servers are optional, graceful fallback)

### Services Affected
- `.claude/` configuration (Toraka project)
- New plugin repo: `project-orchestrator/`

---

### Plugin Structure

```
project-orchestrator/
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── brainstorming/SKILL.md          ← from toraka-brainstorming
│   ├── implementer/SKILL.md            ← from toraka-implementer
│   ├── spec-reviewer/SKILL.md          ← from toraka-spec-reviewer
│   ├── quality-reviewer/SKILL.md       ← from toraka-quality-reviewer
│   ├── verification/SKILL.md           ← from toraka-verification
│   ├── finishing-branch/SKILL.md       ← from toraka-finishing-branch
│   └── changelog/SKILL.md             ← from toraka-changelog
├── commands/
│   ├── brainstorm.md
│   ├── implement.md
│   ├── review.md
│   ├── verify.md
│   ├── finish.md
│   ├── progress.md
│   └── changelog.md
├── agents/
│   ├── implementer.md
│   └── explorer.md
└── README.md
```

### Project Config Convention

Every project using this plugin creates `.claude/project.yml`:

```yaml
# .claude/project.yml — project-orchestrator config
name: my-project

# Repo structure
structure: polyrepo          # polyrepo | monorepo
plans_dir: docs/plans        # where design docs live (relative to root)
plans_structure: standard    # standard = subdirs (completed/backlog/ideas + INDEX.md) | flat = all in one dir

# Architecture docs (optional — skills use these for context)
architecture_docs:
  agent: docs/ARCHITECTURE-AGENT.md
  human: docs/ARCHITECTURE.md
  domain: docs/DOMAIN-GUIDE.md

# Services (for multi-service projects)
services:
  - name: api
    path: api/
    branch: main
    remote: true             # has git remote? affects push behavior
    test: ./gradlew test
    changelog: api/CHANGELOG.md
    auto_deploy: true
  - name: frontend
    path: frontend/
    branch: main
    remote: true
    test: pnpm test
    changelog: frontend/CHANGELOG.md
    auto_deploy: true
  - name: worker
    path: worker/
    branch: main
    remote: true
    test: deno test
    changelog: worker/CHANGELOG.md
    auto_deploy: false

# Implementation behavior (optional — all have defaults)
implementation:
  auto_review: true          # --no-review flag overrides this
  max_parallel: 3            # max parallel implementer agents
```

### Config Validation Strategy

| Condition | Behavior |
|-----------|----------|
| Missing `.claude/project.yml` | Use defaults (monorepo, single service at root, auto-detect test command). Log once. |
| Malformed YAML | Hard error — tell user to fix config |
| Missing referenced file (architecture doc, plans dir) | Warn once, skip that step. Auto-create `plans_dir` on first brainstorm. |
| Invalid service path | Error when that service is targeted by a task |
| Missing `test` for a service | Auto-detect from package.json / build.gradle / Makefile, or skip tests |
| Missing `changelog` for a service | Skip changelog step for that service |
| Missing `branch` for a service | Default to `main` |
| Missing `remote` for a service | Default to `true` |

**Fallback defaults (no config):**
- Structure: monorepo, single service at root
- Plans dir: `docs/plans/`, flat structure
- No architecture docs: skills skip context loading
- Test command: auto-detect
- No changelog: skip

### Config Loading Strategy

Every skill/command begins with:

```
1. Check if .claude/project.yml exists
2. If yes → parse, validate, extract services/paths/test commands
3. If no → use defaults (monorepo, root, auto-detect)
4. Check for architecture docs → read if present
5. Ensure plans_dir exists (create if missing on write operations)
6. Proceed with project-aware context
```

Skills reference `{config.plans_dir}` instead of hardcoded `toraka-docs/plans/`.

---

### Skill Invocation Syntax

After extraction, skills are invoked with the plugin prefix:

| Toraka name | Plugin name |
|-------------|-------------|
| `toraka-brainstorming` | `project-orchestrator:brainstorming` |
| `toraka-implementer` | `project-orchestrator:implementer` |
| `toraka-spec-reviewer` | `project-orchestrator:spec-reviewer` |
| `toraka-quality-reviewer` | `project-orchestrator:quality-reviewer` |
| `toraka-verification` | `project-orchestrator:verification` |
| `toraka-finishing-branch` | `project-orchestrator:finishing-branch` |
| `toraka-changelog` | `project-orchestrator:changelog` |

Commands and agent frontmatter must use the plugin-prefixed names.

---

### Skill-by-Skill Extraction Plan

#### 1. brainstorming/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Reads `toraka-docs/ARCHITECTURE-AGENT.md` + `DOMAIN-GUIDE.md` | Reads paths from `config.architecture_docs` |
| Hardcoded Toraka service list in scope question | Reads `config.services[].name` |
| Living state doc at `toraka-docs/plans/` | Uses `config.plans_dir` |
| Dev-MCP `save_state`/`agent_handoff` | Keep as optional with fallback (already implemented) |
| `toraka-explorer` agent type in team exploration | Uses plugin's own `explorer` agent |
| Toraka-specific design templates (R2DBC, Laravel) | Generic templates + "check service CLAUDE.md for stack-specific patterns" |
| References `.claude/rules/toraka-patterns.md` | "Check service-level CLAUDE.md for stack-specific patterns" |
| Team naming: `brainstorm-{slug}` | Same convention, no change needed |

**Key change:** Replace all service-specific checklists (reactive patterns, API rules) with: "Read the target service's CLAUDE.md for stack-specific patterns and conventions."

#### 2. implementer/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Reads `toraka-docs/ARCHITECTURE-AGENT.md` etc | Reads from `config.architecture_docs` |
| `.claude/rules/toraka-patterns.md` | "Read service-level CLAUDE.md for patterns" |
| Toraka-specific self-review checklist (R2DBC, `/api/v1/`) | Generic checklist + "follow conventions in service CLAUDE.md" |
| Dev-MCP tools (`repo_status`, `acquire_lock`, etc) | Keep as optional with git fallback |
| Service-specific test commands hardcoded | Reads `config.services[name].test` |
| References `toraka-implementer` skill | References `project-orchestrator:implementer` |
| References `postgres` agent for DB tasks | "Use project-specific DB agents if available" |
| Memory at `.claude/agent-memory/implementer/` | Same convention, no change |

#### 3. spec-reviewer/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Toraka-specific checks section (R2DBC, `/api/v1/`, SSE rules) | Remove entirely — replaced with "Check code against patterns in the project's CLAUDE.md and service CLAUDE.md files" |
| References to ARCHITECTURE.md topology | "If architecture docs exist, verify against them" |

**Already mostly generic** — spec compliance is universal. Just remove the Toraka-specific checklist section.

#### 4. quality-reviewer/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Toraka-specific quality checks (R2DBC, Laravel, TanStack) | "Check code against the target service's CLAUDE.md for stack-specific quality patterns" |
| References to specific frameworks | Generic quality dimensions stay (clarity, tests, security, maintainability) |

**Already mostly generic** — remove framework-specific sections.

#### 5. verification/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| MCP `verify_workspace()` / `repo_status()` | Keep as optional, git fallback already exists |
| Toraka-specific test commands | Read from `config.services[name].test` |
| References to specific environment URLs | Removed (environments not in config, document in project CLAUDE.md) |
| Auto-deploy service list | Read from `config.services[].auto_deploy` |
| Living state doc at `toraka-docs/plans/` | Uses `config.plans_dir` |
| Cross-service contract checks (RabbitMQ, SSE) | Generic: "verify API contracts match between producer and consumer services" |

#### 6. finishing-branch/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Toraka-specific auto-deploy warning | Read from `config.services[].auto_deploy` |
| Per-service git repos assumption | Read from `config.structure` (polyrepo vs monorepo) |
| MCP `list_branches` / `verify_workspace` / `repo_status` | Keep as optional with git fallback |
| `toraka-changelog` skill reference | Reference `project-orchestrator:changelog` |
| Living state doc move to `plans/completed/` | Uses `config.plans_dir` + `config.plans_structure` |
| References to specific branch names | Read from `config.services[].branch` |

#### 7. changelog/SKILL.md

| Toraka-specific | Generic replacement |
|-----------------|-------------------|
| Hardcoded service→CHANGELOG.md path table | Read from `config.services[].changelog` |
| Toraka-specific example | Generic example |

**Simplest extraction** — mostly format guidance.

---

### Command Extraction

Commands are thin wrappers that invoke skills. Changes per command:

| Command | Key Changes |
|---------|-------------|
| `brainstorm.md` | Remove `@toraka-docs` refs, invoke `project-orchestrator:brainstorming`, ref `project.yml` |
| `implement.md` | Remove `@toraka-docs` refs, invoke `project-orchestrator:brainstorming` (full lifecycle), scope file optional |
| `review.md` | Invoke `project-orchestrator:spec-reviewer` + `project-orchestrator:quality-reviewer` |
| `verify.md` | Invoke `project-orchestrator:verification` |
| `finish.md` | Remove MCP tool refs from frontmatter, invoke `project-orchestrator:finishing-branch` |
| `progress.md` | Remove MCP tool refs, use file-based plan discovery with `config.plans_dir` |
| `changelog.md` | Invoke `project-orchestrator:changelog` |

**Command naming:** Commands use `project:` prefix → `/project:brainstorm`, `/project:implement`, etc.

---

### Agent Extraction

| Agent | Changes |
|-------|---------|
| `implementer.md` | Remove Toraka-specific context files list, reference `project-orchestrator:implementer` skill, keep memory/model/opus config |
| `explorer.md` | Remove Toraka-specific first-steps, add "read architecture docs from project.yml", keep read-only discipline |

---

### Scope File / Hook Strategy

The auto-approve hook + scope file system is **Toraka-specific infrastructure** — it stays in the Toraka project. The `create_scope()` / `delete_scope()` calls in Toraka's current `/toraka:implement` reference the `toraka-dev-local` MCP server tools. These are NOT new plugin features.

The plugin's `implement.md` command handles scope integration as:

```
5b. Create scope file for auto-approve hook (optional)
   - Try MCP: create_scope(team, services, wave) — graceful fail if unavailable
   - Fallback: Skip scope file creation entirely.
   - Tell user: "Your project can optionally configure auto-approve hooks.
     See plugin README section 'Auto-Approve Integration' for setup."
```

Plugin README includes a section explaining how to set up hooks/scopes for projects that want them.

---

### Toraka Residual Layer

After extraction, Toraka's `.claude/` keeps:

**Stays (Toraka-only):**
- `skills/toraka-scraper-framework/`
- `skills/toraka-cli/`
- `skills/toraka-architecture/` (Toraka-specific dual-doc auditing)
- `skills/toraka-api-contract/` (Toraka-specific topology refs)
- `skills/toraka-debugging/` (has Toraka-specific service debugging)
- `agents/postgres.md`
- `agents/claude-file-auditor.md`
- `hooks/` (all hooks)
- `commands/toraka/scraper.md`
- `commands/toraka/cli.md`
- `commands/toraka/architecture.md`
- `commands/toraka/api-contract.md`
- `commands/toraka/debug.md`

**Removed (replaced by plugin):**
- `skills/toraka-brainstorming/`
- `skills/toraka-implementer/`
- `skills/toraka-spec-reviewer/`
- `skills/toraka-quality-reviewer/`
- `skills/toraka-verification/`
- `skills/toraka-finishing-branch/`
- `skills/toraka-changelog/`
- `commands/toraka/brainstorm.md`
- `commands/toraka/implement.md`
- `commands/toraka/review.md`
- `commands/toraka/verify.md`
- `commands/toraka/finish.md`
- `commands/toraka/progress.md`
- `commands/toraka/changelog.md`
- `agents/implementer.md`
- `agents/toraka-explorer.md`

**New (Toraka adds):**
- `.claude/project.yml` — Toraka's project config for the plugin

---

### Superpowers Coexistence

The plugin doesn't conflict with superpowers because:

1. **Different command prefixes:** `/project:brainstorm` vs `/brainstorm` (superpowers)
2. **Skills have different names:** `project-orchestrator:brainstorming` vs `superpowers:brainstorming`
3. **Plugin skills are supersets** — they do everything superpowers does plus multi-service coordination, living state docs, and team orchestration
4. **User chooses per-task** — simple single-file feature → superpowers. Multi-service feature → project-orchestrator.

---

### Design Smells Check

| Smell | Assessment |
|-------|-----------|
| >3 services affected | No — just `.claude/` config |
| Overengineering? | Config schema is minimal — only what's needed |
| New dependencies? | None — pure skill/command files |
| "We'll need to..." | No speculative features |

---

### Future Enhancements (not in v1)

- Service dependency graph in config (e.g., frontend depends on backend)
- Default task wave ordering hints (DB migrations before app code)
- `environments:` section for programmatic env switching
- Built-in auto-approve hook template

---

## Implementation Tasks

| # | Task | Status | Assignee | Spec | Quality |
|---|------|--------|----------|------|---------|
| 1 | Create plugin scaffold (plugin.json, directory structure, README) | complete | lead | — | — |
| 2 | Write `.claude/project.yml` schema docs + validation rules in README | complete | lead | — | — |
| 3a | Extract `brainstorming/SKILL.md` — remove Toraka refs, use config conventions | complete | lead | — | — |
| 3b | Update brainstorming team/agent references to plugin conventions | complete | lead | — | — |
| 4 | Extract `implementer/SKILL.md` — remove Toraka refs, use config conventions | complete | lead | — | — |
| 5 | Extract `spec-reviewer/SKILL.md` — remove Toraka-specific checks | complete | lead | — | — |
| 6 | Extract `quality-reviewer/SKILL.md` — remove framework-specific sections | complete | lead | — | — |
| 7 | Extract `verification/SKILL.md` — use config for test commands | complete | lead | — | — |
| 8 | Extract `finishing-branch/SKILL.md` — use config for deploy/branch info | complete | lead | — | — |
| 9 | Extract `changelog/SKILL.md` — use config for changelog paths | complete | lead | — | — |
| 10 | Create all 7 commands with `project:` prefix | complete | lead | — | — |
| 11 | Create `implementer.md` and `explorer.md` agent definitions | complete | lead | — | — |
| 12 | Create Toraka's `.claude/project.yml` config file | complete | lead | — | — |
| 13a | Remove replaced skills/commands/agents from Toraka `.claude/` | complete | lead | — | — |
| 13b | Update references in remaining Toraka skills (debug, architecture, etc.) | complete | lead | — | — |
| 13c | Update Toraka CLAUDE.md commands table | complete | lead | — | — |
| 14 | Test plugin in a non-Toraka sample project | skipped | — | — | — |

### Dependencies

- Task 2 (config schema) blocks tasks 3a-12 (everyone needs to know config structure)
- Tasks 3a, 4-9 can run in parallel (independent skill extractions)
- Task 3b depends on 3a
- Task 10 depends on tasks 3a-9 (commands reference skills)
- Task 11 depends on tasks 3a + 4 (agents reference skill names)
- Task 12 depends on task 2 (needs schema)
- Tasks 13a-13c depend on all others
- Task 14 depends on tasks 1-12

### Shared Files — Collision Risk

No shared file collisions — each task targets different files.

## Implementation Log

### 2026-02-14 — All tasks completed by lead agent (single-session)

**Approach:** All tasks handled directly by lead (no team needed) — source skills were already in context, transformations well-defined in design doc tables.

**Files created (plugin):**
- `project-orchestrator/.claude-plugin/plugin.json` — plugin manifest
- `project-orchestrator/README.md` — config schema, validation rules, usage docs
- `project-orchestrator/skills/brainstorming/SKILL.md` — 423→390 lines, removed Toraka service list, hardcoded paths, toraka-core templates
- `project-orchestrator/skills/implementer/SKILL.md` — 156→145 lines, removed Toraka-specific patterns section, config-driven test commands
- `project-orchestrator/skills/spec-reviewer/SKILL.md` — 101→95 lines, replaced Toraka-specific checks with "check service CLAUDE.md"
- `project-orchestrator/skills/quality-reviewer/SKILL.md` — 123→105 lines, removed framework-specific sections
- `project-orchestrator/skills/verification/SKILL.md` — 170→155 lines, config-driven test commands and plan paths
- `project-orchestrator/skills/finishing-branch/SKILL.md` — 219→200 lines, config-driven branches, auto-deploy, plan structure
- `project-orchestrator/skills/changelog/SKILL.md` — 84→75 lines, config-driven changelog paths
- `project-orchestrator/commands/{brainstorm,implement,review,verify,finish,progress,changelog}.md` — all 7 commands with `project:` prefix
- `project-orchestrator/agents/{implementer,explorer}.md` — agent definitions referencing plugin skills

**Files created (Toraka):**
- `.claude/project.yml` — Toraka project config for the plugin (all 10 services)

**Files removed (Toraka):**
- 7 skill directories: `toraka-{brainstorming,implementer,spec-reviewer,quality-reviewer,verification,finishing-branch,changelog}/`
- 7 commands: `toraka/{brainstorm,implement,review,verify,finish,progress,changelog}.md`
- 2 agents: `implementer.md`, `toraka-explorer.md`

**Files modified (Toraka):**
- `.claude/skills/toraka-debugging/SKILL.md` — `/toraka:verify` → `/project:verify`, `/toraka:finish` → `/project:finish`
- `.claude/skills/toraka-scraper-framework/SKILL.md` — `/toraka:changelog` → `/project:changelog`
- `.claude/commands/toraka/scraper.md` — `/toraka:changelog` → `/project:changelog`
- `CLAUDE.md` — updated commands table with `project:` prefix section

**Task 14 (testing in non-Toraka project):** Skipped — requires a separate project to test against. User can run manually.

## Decisions & Context

1. **Convention over configuration** — if no `project.yml` exists, skills degrade gracefully to monorepo/single-service defaults
2. **Architecture docs are optional** — not all projects have ARCHITECTURE.md. Skills skip context loading if paths aren't configured
3. **MCP stays optional** — all MCP tool calls already have git-based fallbacks. No new MCP dependency.
4. **Scope hooks stay in Toraka** — the auto-approve hook system is too project-specific and infrastructure-heavy to generalize. Plugin documents how to set up hooks but doesn't ship them.
5. **Plugin doesn't replace superpowers** — coexists. Superpowers for simple tasks, project-orchestrator for multi-service orchestration.
6. **Command prefix: `project:`** — e.g., `/project:brainstorm`, `/project:implement`
7. **Agent model preference stays opus** — implementer agent uses opus model (configurable per project via agent frontmatter)
8. **No `environments` in config** — environment URLs go in project CLAUDE.md. May add in future version if needed.
9. **Plans dir auto-created** — skills create `plans_dir` on first write if it doesn't exist
10. **Config validation is strict on structure, lenient on optional fields** — malformed YAML = hard error, missing optional fields = defaults
