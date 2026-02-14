---
name: project:brainstorm
description: Start the feature lifecycle — brainstorm and design phase
argument-hint: "[feature description]"
allowed-tools: [Read, Glob, Grep, Task, AskUserQuestion]
skills: [project-orchestrator:brainstorming]
---

<objective>
Design phase orchestrator. Invoke the brainstorming skill to turn a feature idea into an approved design document. Stops before implementation — that's `/project:implement`.
</objective>

<context>
- `$ARGUMENTS` — feature description (skip "what's the feature?" if provided)
</context>

<process>
1. Load project config from `.claude/project.yml` (defaults if missing)
2. Read architecture docs if configured (`config.architecture_docs.agent`, `config.architecture_docs.domain`)
3. Invoke the `project-orchestrator:brainstorming` skill to guide this feature through the **design phase only**
4. **When spawning Explore agents**, always include relevant sections from the architecture docs in each agent's prompt — subagents don't inherit your context
5. If `$ARGUMENTS` provided, use as starting point — skip asking "what's the feature idea?" and move directly to scoping which services are affected
6. If no description provided, ask the user what they want to build
7. **Phase boundary:** Stop after the design phase is complete (living state doc written and approved). Do NOT continue into implementation.
8. When design is approved, tell the user:
   ```
   Design complete. Next steps:
   1. Run /clear to free up context
   2. Run /project:implement to start parallel implementation
      - Add --no-review to skip auto-review after each task
   3. Run /project:progress anytime to check status
   ```
</process>

<success_criteria>
- [ ] Design doc written to `{config.plans_dir}/YYYY-MM-DD-{slug}-design.md`
- [ ] Design approved by user
- [ ] User told next steps (`/project:implement`, `/project:progress`)
</success_criteria>
