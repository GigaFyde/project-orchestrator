---
name: project:implement
description: Execute implementation from a design doc — creates team, spawns parallel workers, post-implementation review
argument-hint: "[plan file path] [--no-review]"
---

<objective>
Implementation team orchestrator. Read a design doc, create a team, spawn parallel implementers, coordinate completion, and run a single review pass after all tasks complete.
</objective>

<context>
- `$ARGUMENTS` — plan file path + optional `--no-review` flag
- Project config: @.claude/project.yml
- Plans index: @docs/plans/INDEX.md
</context>

<process>
1. **Parse project config** (auto-loaded via @.claude/project.yml, use defaults if missing)
   - Extract `models.implementer` (default: opus) for spawning implementer agents
   - Extract `review.strategy`, `review.parallel_models`, `review.single_model` for post-implementation review
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

5a. **Check for `--no-review` flag** — if present, skip the post-implementation review pass entirely. Default: review enabled.

6. **Write orchestrator state file**
   Write `.project-orchestrator/state.json` so hooks can find the active plan immediately when implementation starts.
   - Build JSON with: `active_plan` (relative path to design doc), `slug`, `team` ("implement-{slug}"), `started` (ISO 8601 timestamp), `worktrees` (from step 5.5)
   - Worktrees field structure:
     - Polyrepo: `{ "service-name": "/abs/path/to/worktree" }` per service
     - Monorepo: `{ "_all": "/abs/path/to/worktree" }`
     - No worktrees: `{}`
   - **Atomic write:** Write to a temp file first (`.project-orchestrator/state.json.tmp`), then `mv` to final path to prevent read-during-write corruption
   - Ensure `.project-orchestrator/` directory exists before writing
   - **If write fails:** Report error to user and exit — no cleanup needed (team doesn't exist yet)

6a. **Create implementation team**
   ```
   TeamCreate("implement-{slug}")
   ```
   - **If TeamCreate fails:**
     - Delete `.project-orchestrator/state.json` (clean up the state file from step 6)
     - Leave `.project-orchestrator/` directory intact (may be used by other files)
     - Report error to user, exit

6b. **Create scope file for auto-approve hook**
   - Extract service names from design doc's "Services Affected"
   - For each service:
     - If config.services exists: look up service.path for the directory
     - If no config: use service name as relative path (monorepo default)
     - If worktrees active (from step 5.5): use worktree paths instead of service paths
   - Build scope JSON matching the hook's expected schema:
     - `"shared"` array: all service directory paths (relative to project root)
     - Per-agent keys added later when spawning workers (step 7) if task-specific scoping needed
   - Write `.project-orchestrator/scopes/{team-name}.json` via Write tool
   - Ensure `.project-orchestrator/scopes/` directory exists before writing
   - Try MCP `create_scope(team, services, wave)` as optimization — but the Write approach above is the primary path

   Scope file format (must match scope-protection.sh expectations):
   ```json
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"]
   }
   ```

   Per-agent scoping (optional, added during step 7 if tasks have specific file lists):
   ```json
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"],
     "implement-t1": ["service1/src/specific/path/"],
     "implement-t2": ["service2/src/specific/path/"]
   }
   ```

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
   - Update living state doc — mark task as `complete`, log implementer report
   - Check if blocked tasks are now unblocked, start next wave
   - **Task assignment messaging rules:**
     a) Never combine "task done ack" + "new task assignment" in one SendMessage call
     b) Skip the acknowledgment entirely — just send the new task assignment
     c) Include the full task description from TaskGet({task-id}).description
     d) Format (single SendMessage call, no preceding ack):
        ```
        "TASK #{N}: {task title}
         {full task description}"
        ```
     e) When starting a new wave: send individual task assignments (one SendMessage per agent)
     f) If no more tasks for this agent, send shutdown request

     WRONG — combined ack + assignment in one message:
       `SendMessage("Task 1 done, good work. Now do Task 2: ...")`

     WRONG — ack followed by assignment as separate messages:
       `SendMessage("Task 1 confirmed.")`
       `SendMessage("Now do Task 2: ...")`

     RIGHT — assignment only, no ack:
       `SendMessage("TASK #2: Add retry logic to R2dbcSupport\n{full description}")`

   - **Lead idle detection** — when an implementer goes idle WITHOUT sending a completion report:
     a) Check `git diff --stat` in the service directory
     b) Read the task description to understand expected scope
     c) Incompleteness heuristics — if ANY of these apply, work is likely incomplete:
        - Only imports added (no logic changes)
        - Only type definitions or interfaces (no usage)
        - No tests added when task description mentions "add tests"
        - Commit message says "WIP" or "partial"
        - Fewer files changed than task description implies
     d) If obviously incomplete:
        - Resume the agent with: "Your work on Task #{N} appears incomplete.
          Missing: {specific items from task description}. Please continue."
     e) If plausibly complete but no report was sent:
        - Resume with: "Please verify your Task #{N} work is complete and
          send your completion report."
     f) "Progress" = agent commits new changes (visible in git diff) or sends a
        completion/progress message. Resume count increments each time the lead
        sends a resume message and the agent goes idle without progress.
     g) After 2 resume attempts with no progress:
        - Mark task as "blocked" in living state doc
        - Message user: "Task #{N} appears stuck. Agent made no progress after
          2 resume attempts. Last known state: {git diff summary}.
          Options: 1) Manually guide agent, 2) Reassign to new agent,
          3) Skip task and continue with next wave."
        - Wait for user decision before proceeding

9. **Post-implementation review** (unless `--no-review`):

   After ALL implementation tasks are complete, run `/project:review` against the full implementation diff. This is a holistic diff-based review (spec + quality in parallel), not per-task. See `/project:review` for the full process.

   - If review passes: proceed to completion
   - If review finds egregious issues: offer to fix with user approval, then re-review
   - If review finds ambiguous issues: present to user for decision

10. **Completion**
   - Delete scope file (MCP `delete_scope` or skip)
   - TeamDelete("implement-{slug}")
   - Delete `.project-orchestrator/state.json` (clean up active plan marker now that implementation is done)
   - Update living state doc status to "complete"
   - If `config.plans_structure` is `standard`: move design doc to `{plans_dir}/completed/` and update INDEX.md
   - Tell the user next steps:
     - If review passed: "Implementation complete. Next steps: `/project:verify` then `/project:finish`"
     - If `--no-review` was used: "Implementation complete. Next steps: `/project:review` → `/project:verify` → `/project:finish`"
</process>

<success_criteria>
- [ ] All implementation tasks complete
- [ ] Post-implementation review passed (unless `--no-review`)
- [ ] Review findings presented to user if issues found
- [ ] Analytics entry written to `.project-orchestrator/review-analytics.json` (unless `--no-review`)
- [ ] Living state doc updated with final status
- [ ] Team cleaned up via TeamDelete
- [ ] `.project-orchestrator/state.json` deleted after TeamDelete
- [ ] User told next steps (includes `/project:review` when `--no-review` was used)
</success_criteria>
