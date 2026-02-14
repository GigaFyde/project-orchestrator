# project-orchestrator

Full-lifecycle project orchestration plugin for Claude Code. Turns feature ideas into designs and implementations using parallel teams, two-stage review, and living state documents.

## Installation

Add to your project's `.claude/settings.json`:

```json
{
  "plugins": ["path/to/project-orchestrator"]
}
```

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

Create `.claude/project.yml` in your project root. All fields are optional — the plugin uses sensible defaults when config is missing.

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
```

### Config Validation

| Condition | Behavior |
|-----------|----------|
| Missing `.claude/project.yml` | Defaults: monorepo, single service at root, auto-detect test command |
| Malformed YAML | Hard error — fix config before proceeding |
| Missing referenced file (architecture doc, plans dir) | Warn once, skip that step. Auto-create `plans_dir` on first brainstorm |
| Invalid service path | Error when that service is targeted by a task |
| Missing `test` for a service | Auto-detect from package.json / build.gradle / Makefile, or skip tests |
| Missing `changelog` for a service | Skip changelog step for that service |
| Missing `branch` for a service | Default to `main` |
| Missing `remote` for a service | Default to `true` |

### No Config (Zero-Config Mode)

Without `project.yml`, the plugin assumes:
- **Structure:** monorepo, single service at root
- **Plans dir:** `docs/plans/`, flat structure
- **Architecture docs:** none (skills skip context loading)
- **Test command:** auto-detected from package.json / build.gradle / Makefile
- **Changelog:** none (skip changelog step)

## Config Loading

Every skill/command begins with:

1. Check if `.claude/project.yml` exists
2. If yes: parse, validate, extract services/paths/test commands
3. If no: use defaults (monorepo, root, auto-detect)
4. Check for architecture docs: read if present
5. Ensure `plans_dir` exists (create if missing on write operations)
6. Proceed with project-aware context

## Agents

| Agent | Purpose | Model |
|-------|---------|-------|
| `implementer` | Implements tasks from design docs | opus |
| `explorer` | Read-only codebase exploration | sonnet |

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
2. Scope files at `.claude/hooks/scopes/{team}.json`
3. An MCP tool or manual process to create/delete scope files per implementation wave
