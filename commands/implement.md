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
   - Extract `models.implementer` (default: opus) for spawning implementer agents
   - Extract `review.strategy`, `review.parallel_models`, `review.single_model` for auto-review
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

5.5. **Check for overlapping active plans**
   - Check if current design doc already has a `## Worktree` / `## Worktrees` section
     - If yes: reuse existing worktree(s)
       - Verify they exist on disk via `git worktree list`
       - If missing: run `git worktree prune`, then recreate via `project-orchestrator:worktree` skill
       - Verify correct branch: `cd {worktree} && git branch --show-current` should match the branch in the design doc
       - If wrong branch: warn user, don't silently proceed
   - If no existing worktree section: scan `{config.plans_dir}/` for other `*-design.md` with status `implementing`
     - Extract `Services Affected` list from each
     - Intersect with current plan's services
     - If overlap found:
       - Tell user which plan overlaps and on which services
       - Offer worktree isolation
       - If accepted: invoke `project-orchestrator:worktree` skill, record absolute path(s) in design doc
       - If declined: proceed without worktree (user accepts collision risk)
   - Store worktree info (path or service→path map) for use in step 7

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
   - **Task-service mapping (for worktree routing):** For each task, look up the `Service` column in the design doc's task table. If a `## Worktrees` table exists (polyrepo), find the matching service row to get the worktree path. If `## Worktree` exists (monorepo), use the single worktree path. If no worktree section exists, use the project root or service path.
   - For each wave (up to `config.implementation.max_parallel` tasks, default 3):
     ```
     Task(implementer, model: config.models.implementer (default: opus), team_name: "implement-{slug}", name: "implement-{task-slug}")
     Prompt (monorepo):
       Your task: Task {N} — {title}
       Living state doc: {path to design doc}
       Working directory: {absolute worktree path or project root}
       Read the living state doc, then cd into the working directory and implement your task.

     Prompt (polyrepo):
       Your task: Task {N} — {title}
       Living state doc: {path to design doc}
       Service: {service name}
       Working directory: {absolute worktree path for this service, or service path}
       Read the living state doc, then cd into the working directory and implement your task.
     ```
   - Update living state doc: mark task as `in-progress`, set assignee
   - Wait for each wave to complete before starting the next

8. **Handle task completion** — when an implementer reports via SendMessage:
   - a) Update living state doc — mark task status, log implementer report
   - b) If auto-review enabled (follows same strategy as `/project:review`):
     - When `config.review.strategy: parallel` (default): spawn 2 spec-reviewer agents with `config.review.parallel_models` models, merge findings
     - When `config.review.strategy: single`: spawn 1 spec-reviewer agent with `config.review.single_model`
     - If spec passes → same pattern for quality-reviewer agents
     - If review finds issues → SendMessage to implementer with specific fixes → re-review after fix
   - c) Update living state doc with review results

9. **Completion**
   - Run a final whole-implementation code review (fresh Task, quality-reviewer, model per config.review.strategy)
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
