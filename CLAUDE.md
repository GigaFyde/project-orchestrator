# Project Orchestrator Plugin

Claude Code plugin for multi-service feature orchestration using parallel agent teams.

## Structure

This is a Claude Code plugin (not a runnable app). No build step, no dependencies, no tests.

```
.claude-plugin/plugin.json   # Plugin manifest (name, version)
agents/                       # Agent definitions (.md with YAML frontmatter)
commands/                     # Slash commands (.md with YAML frontmatter)
skills/                       # Skills (subdirs with SKILL.md)
docs/plans/                   # Design docs (active plans + completed/)
```

## Plugin Components

- **Commands** (`/project:brainstorm`, `/project:implement`, `/project:review`, `/project:verify`, `/project:finish`, `/project:progress`, `/project:changelog`) — user-invoked entry points
- **Skills** — detailed process instructions loaded by commands and agents
- **Agents** — specialized subagent definitions (implementer, explorer, spec-reviewer, quality-reviewer)

## Key Concepts

- **Living state doc**: Design docs in `docs/plans/` that get updated as implementation progresses (status, assignees, review results)
- **Wave-based implementation**: Independent tasks run in parallel waves; dependent tasks are sequenced
- **Two-stage review**: Spec compliance first, then code quality — each can use parallel or single model strategy
- **Project config**: Consumer projects configure via `.claude/project.yml` (optional — sensible defaults without it)
- **Context boundaries**: `/clear`, subagent spawns, and skill invocations all lose conversation context — skills must be self-sufficient

## Conventions

- All component files are Markdown with YAML frontmatter
- Skills reference config values like `config.models.implementer` — these come from the consumer's `.claude/project.yml`
- MCP tool calls (Dev-MCP) are always wrapped in graceful failure — the plugin works without MCP
- Commands and skills are self-contained for context: they explicitly instruct reading needed files because `/clear` and subagent spawns lose conversation context

## Common Mistakes

### Editing Skills/Commands
- **`@` file refs in commands are fine for reinforcement** — but skills must still explicitly instruct reading needed files, since `@` refs are lost on `/clear` and subagent spawns
- **Don't hardcode paths** — use config values (e.g., `config.plans_dir`) so consumer projects can override
- **Don't assume MCP tools exist** — always wrap in "try MCP, fallback to file-based approach"
- **Keep skills self-sufficient** — a skill may be invoked in a fresh context with zero prior conversation

### Plugin Architecture
- **This repo is NOT the consumer project** — `docs/plans/` here contains plans for developing the plugin itself, not example consumer plans
- **Don't add runtime dependencies** — this is pure Markdown, no package.json, no build
- **Test changes by using the plugin** — install in a consumer project and run the commands

### Config Schema
- **Config lives in the consumer project** (`.claude/project.yml`), not in this repo
- **All config fields are optional** — skills must handle missing config gracefully with defaults
- **`review.*` config is separate from `models.*`** — reviewer models come from review config, not the general models section

## Git

- Main branch: `main`
- No CI/CD — plugin distributed by path reference
- Design docs for plugin development live in `docs/plans/` (completed ones in `docs/plans/completed/`)
