---
name: project:implement
description: Execute implementation from a design doc — creates team, spawns parallel workers, optional auto-review
argument-hint: "[plan file path] [--no-review]"
---

<objective>
Implementation team orchestrator. Read a design doc, create a team, spawn parallel implementers, coordinate completion, and optionally auto-review each task.
</objective>

<context>
- `$ARGUMENTS` — plan file path + optional `--no-review` flag
</context>

<process>
1. **Load project config** from `.claude/project.yml` (defaults if missing)
2. Read architecture docs if configured

3. **Check for handoff and saved state (Dev-MCP)**
   - Try `receive_handoff(agent_id: "implement-lead")` — if handoff exists from brainstorm phase, use context
   - Try `load_state(prefix: "implement-{slug}")` — if saved state exists, resume from checkpoint
   - **Fallback:** If MCP unavailable or no handoff/state found, proceed with file-based approach below

4. **Find the design doc**
   - If handoff provided design_doc path, use it
   - If a plan file path was provided in arguments, use it
   - Otherwise, check `{config.plans_dir}/INDEX.md` for active plans, or find `{config.plans_dir}/*-design.md`
   - If no design doc exists, tell the user: "No design doc found. Run `/project:brainstorm` first."

5. **Parse the design doc** — extract feature name/slug, implementation tasks, dependencies, current status

5a. **Check for `--no-review` flag** — if present, skip auto-review after task completion. Default: `config.implementation.auto_review` (default true).

6. **Create implementation team**
   ```
   TeamCreate("implement-{slug}")
   ```

6b. **Create scope file for auto-approve hook (optional)**
   - Try MCP: `create_scope(team, services, wave)` — graceful fail if unavailable
   - Fallback: Skip scope file creation entirely

7. **Create tasks and spawn workers**
   - Create TaskCreate entries with dependencies (addBlockedBy for dependent tasks)
   - Group independent tasks into waves (tasks with no unresolved blockers = same wave)
   - **Same-file collision detection:** Before spawning a wave, check if 2+ tasks edit the same file(s). If so:
     - a) **Sequence them** — put colliding tasks in separate waves (safest)
     - b) **Component-first isolation** — each agent builds standalone files, then integration task wires them in
     - c) **Git worktrees** — give each agent its own worktree, merge after
   - For each wave (up to `config.implementation.max_parallel` tasks, default 3):
     ```
     Task(implementer, team_name: "implement-{slug}", name: "implement-{task-slug}")
     Prompt:
       Your task: Task {N} — {title}
       Living state doc: {path to design doc}
       Read the living state doc for full design context, then implement your assigned task.
     ```
   - Update living state doc: mark task as `in-progress`, set assignee
   - Wait for each wave to complete before starting the next

8. **Handle task completion** — when an implementer reports via SendMessage:
   - a) Update living state doc — mark task status, log implementer report
   - b) If auto-review enabled:
     - Spawn spec reviewer (fresh Task agent, general-purpose, opus) → `project-orchestrator:spec-reviewer` skill
     - If spec passes → spawn quality reviewer (fresh Task, feature-dev:code-reviewer, opus) → `project-orchestrator:quality-reviewer` skill
     - If review finds issues → SendMessage to implementer with specific fixes → re-review after fix
   - c) Update living state doc with review results

9. **Completion**
   - Run a final whole-implementation code review (fresh Task, feature-dev:code-reviewer)
   - Delete scope file (MCP `delete_scope` or skip)
   - TeamDelete("implement-{slug}")
   - Update living state doc status to "complete"
   - If `config.plans_structure` is `standard`: move design doc to `{plans_dir}/completed/` and update INDEX.md
   - Tell the user: "Implementation complete. Next steps: `/project:verify` then `/project:finish`"
</process>

<success_criteria>
- [ ] All implementation tasks complete
- [ ] Reviews passed (if auto-review enabled)
- [ ] Living state doc updated with final status
- [ ] Team cleaned up via TeamDelete
- [ ] User told next steps (`/project:verify`, `/project:finish`)
</success_criteria>
