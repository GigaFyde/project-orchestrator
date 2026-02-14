# Autoload Config via @ Refs — Design & Implementation

## Status: complete

## Design

### Feature Type
Configuration/infra — plugin command improvement

### Services Affected
- project-orchestrator (this plugin)

### Design Details

#### Problem
Every command starts with `Read(.claude/project.yml)` as its first tool call, wasting a round-trip. Commands that need the plans INDEX also waste calls on `Glob` + `Read` for INDEX.md. Example from Toraka's `/project:implement`:

```
Read(.claude/project.yml)           ← wasted
Search("toraka-docs/plans/INDEX.md") ← wasted
Read(toraka-docs/plans/INDEX.md)     ← wasted
```

#### Solution
Add `@` file references in command bodies so Claude Code auto-includes file content when the command loads. Two files:

1. **`@.claude/project.yml`** — always at this fixed path, works for all consumer projects
2. **`@docs/plans/INDEX.md`** — default `plans_dir` path; gracefully fails for projects with custom `plans_dir` (they still fall back to explicit Read in the skill)

#### Syntax
Add a context section to each command body:

```markdown
<context>
- `$ARGUMENTS` — ...
- Project config: @.claude/project.yml
- Plans index: @docs/plans/INDEX.md
</context>
```

#### Which commands get which refs

| Command | `@.claude/project.yml` | `@docs/plans/INDEX.md` |
|---------|----------------------|----------------------|
| implement | yes | yes |
| review | yes | yes |
| review-design | yes | yes |
| progress | yes | yes |
| brainstorm | yes | no (writes INDEX via skill, never reads it) |
| worktree | yes | no (globs for design docs directly) |
| verify | yes | no (finds design doc via plans_dir glob) |
| finish | yes | no |
| changelog | yes | no |

#### Process step wording
Commands currently say `Load project config from .claude/project.yml`. Update to:
```
1. Parse project config (auto-loaded via @.claude/project.yml, use defaults if missing)
```

#### What stays the same
- **Skills assume config is in context** — skills say "Check if `.claude/project.yml` exists" and "parse and extract", they don't explicitly Read it. The `@` ref ensures config is available when invoked via command. After `/clear`, commands re-load it via `@` ref. Subagent spawns must include relevant config in prompts (skills already do this for architecture docs).
- **No skill changes needed** — skills are already compatible with this approach

#### Graceful failure
- If `.claude/project.yml` doesn't exist → command proceeds with defaults (same as today)
- If `docs/plans/INDEX.md` doesn't exist (custom `plans_dir`) → skill falls back to Glob + Read (same as today)

## Implementation Tasks

| # | Task | Status | Assignee | Spec | Quality |
|---|------|--------|----------|------|---------|
| 1 | Add @ refs and update process wording in all 9 command files | complete | lead | ✅ | ✅ |

## Decisions & Context
- Single task — all 9 commands are in the same repo, same pattern, no parallelism needed
- INDEX.md ref uses default path (`docs/plans/`) only — `@` refs can't be dynamic, so custom `plans_dir` projects gracefully degrade to Glob + Read via skills
- No changes to skills or agents — they remain self-sufficient for context boundaries
- Process step wording updated from "Load" to "Parse (auto-loaded)" to reflect that config is already in context
