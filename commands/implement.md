---
name: project:implement
description: Execute implementation from a design doc — creates team, spawns parallel workers, post-implementation review
argument-hint: "[plan file path] [--no-review] [--no-auto-resume]"
allowed-tools: [Read, Glob, Grep, Bash, Edit, Write, Task, Skill, AskUserQuestion]
---

<objective>
Implementation team orchestrator. Read a design doc, create a team, spawn parallel implementers, coordinate completion, and run a single review pass after all tasks complete.
</objective>

<context>
- `$ARGUMENTS` — plan file path + optional `--no-review` and `--no-auto-resume` flags
- Project config: @.project-orchestrator/project.yml
- Plans index: @docs/plans/INDEX.md
</context>

<process>
1. **Parse project config** (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)
   - Extract `models.implementer` (default: opus) for spawning implementer agents
   - Extract `review.strategy`, `review.parallel_models`, `review.single_model` for post-implementation review
2. Read architecture docs if configured

3. **Find the design doc**
   - If a plan file path was provided in arguments, use it
   - Otherwise, check `{config.plans_dir}/INDEX.md` for active plans, or find `{config.plans_dir}/*-design.md`
   - If no design doc exists, tell the user: "No design doc found. Run `/project:brainstorm` first."

4. **Parse the design doc** — extract feature name/slug, implementation tasks, dependencies, current status

4.5. **Check for overlapping active plans**
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
   - Store worktree info (path or service→path map) for use in step 6

4a. **Check for flags:**
   - `--no-review` — if present, skip the post-implementation review pass entirely. Default: review enabled.
   - `--no-auto-resume` — if present, immediately escalate to user on any idle without completion (skip auto-resume). Default: auto-resume enabled.

5. **Write orchestrator state file**
   Write `.project-orchestrator/state.json` so hooks can find the active plan immediately when implementation starts.
   - Build JSON with: `active_plan` (relative path to design doc), `slug`, `team` ("implement-{slug}"), `started` (ISO 8601 timestamp), `worktrees` (from step 4.5)
   - Worktrees field structure:
     - Polyrepo: `{ "service-name": "/abs/path/to/worktree" }` per service
     - Monorepo: `{ "_all": "/abs/path/to/worktree" }`
     - No worktrees: `{}`
   - **Atomic write:** Write to a temp file first (`.project-orchestrator/state.json.tmp`), then `mv` to final path to prevent read-during-write corruption
   - Ensure `.project-orchestrator/` directory exists before writing
   - **If write fails:** Report error to user and exit — no cleanup needed (team doesn't exist yet)

5a. **Create implementation team**
   ```
   TeamCreate("implement-{slug}")
   ```
   - **If TeamCreate fails:**
     - Delete `.project-orchestrator/state.json` (clean up the state file from step 5)
     - Leave `.project-orchestrator/` directory intact (may be used by other files)
     - Report error to user, exit

5b. **Create scope file for auto-approve hook**
   - Extract service names from design doc's "Services Affected"
   - For each service:
     - If config.services exists: look up service.path for the directory
     - If no config: use service name as relative path (monorepo default)
     - If worktrees active (from step 4.5): use worktree paths instead of service paths
   - Build scope JSON matching the hook's expected schema:
     - `"shared"` array: all service directory paths (relative to project root)
     - Per-agent keys added later when spawning workers (step 6) if task-specific scoping needed
   - Write `.project-orchestrator/scopes/{team-name}.json` via Write tool
   - Ensure `.project-orchestrator/scopes/` directory exists before writing

   Scope file format (must match scope-protection.sh expectations):
   ```json
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"]
   }
   ```

   Per-agent scoping (optional, added during step 6 if tasks have specific file lists):
   ```json
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"],
     "implement-t1": ["service1/src/specific/path/"],
     "implement-t2": ["service2/src/specific/path/"]
   }
   ```

6. **Create tasks and spawn workers**
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
   - **Capture base commit SHA** for idle detection: run `git rev-parse HEAD` in the working directory (worktree or project root) after spawning each agent. Store the SHA per-agent — used later by NO_CHANGES classification to detect whether the agent made any commits.
   - Update living state doc: mark task as `in-progress`, set assignee
   - Wait for each wave to complete before starting the next

7. **Handle task completion** — when an implementer reports via SendMessage:
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

     **If `--no-auto-resume`:** Skip classification and auto-recovery. Immediately escalate to user:
     "Task #{N} agent went idle without completion report. Git diff: {summary}. How to proceed?"

     **Otherwise (default — auto-resume enabled):**

     a) **Classify failure** using observable signals (first match wins).
        For worktree-routed tasks, run all git commands inside the worktree directory, not the project root.

        - **NO_CHANGES** — no new commits on the feature branch since agent spawn
          (compare HEAD against base commit SHA stored at spawn time) AND
          `git diff --stat` shows 0 uncommitted changes AND agent sent no
          progress/blocking message
          → Resume with: "You haven't made any code changes yet. Start implementing
            Task #{N} now. Key files to edit: {inferred from task description}.
            Do not explore further — begin editing."

        - **STALLED** — agent sent a build-failed or stuck message but went idle
          without resolving
          → Resume with: "You reported a build/test failure. Here's your last error
            message: {quote from agent's message}. Fix the issue, re-run build/tests,
            then send completion report."
          → Fallback: if no message was sent but git diff shows changes (commits or
            uncommitted), treat as PARTIAL_WORK instead of NO_CHANGES.

        - **PARTIAL_WORK** — `git diff --stat` shows changes but task is incomplete
          per these heuristics (if ANY apply, work is likely incomplete):
          - Only imports added (no logic changes)
          - Only type definitions or interfaces (no usage)
          - No tests added when task description mentions "add tests"
          - Commit message says "WIP" or "partial"
          - Fewer files changed than task description implies
          → Resume with specific missing items from task description:
            "Your work on Task #{N} appears incomplete. Missing: {items}. Please continue."
          → If in a worktree: include in recovery message: "Before continuing, verify
            your worktree is healthy: git status should not error."
          → If plausibly complete but no report: resume with "Please verify your Task #{N}
            work is complete and send your completion report."

     b) **Progress definition** for retry gating:
        "Progress" means EITHER new commits since last idle detection (git log comparison)
        OR agent sent a new message since last idle detection.
        Compare state between consecutive idle detections, not against initial state.

     c) **Recovery tracking:** Append to the task's Implementation Log entry:
        `- **Recovery:** {failure_type} (attempt {N})`
        Only written when recovery occurs. Append-only — does not change existing log format.

     d) **Escalation after failed recovery:** After 2 resume attempts with no progress:
        - Mark task as "blocked" in living state doc
        - Message user: "Task #{N} appears stuck. Agent made no progress after
          2 resume attempts. Classification: {last failure type}. Last known state: {git diff summary}.
          Options: 1) Manually guide agent, 2) Reassign to new agent,
          3) Skip task and continue with next wave."
        - Wait for user decision before proceeding

8. **Post-implementation review** (unless `--no-review`):

   After ALL implementation tasks are complete, invoke the review skill:
   ```
   Skill(project-orchestrator:review, args: "{path to design doc}")
   ```
   **You MUST use the `project-orchestrator:review` skill via the Skill tool.** Do NOT use generic code-review agents, the `feature-dev:code-reviewer`, or any other review mechanism. The review skill spawns the plugin's own spec-reviewer and quality-reviewer agents with the correct parallel/single strategy from project config.

   - If review passes: proceed to completion
   - If review finds egregious issues: offer to fix with user approval, then re-review
   - If review finds ambiguous issues: present to user for decision

9. **Completion**
   - Delete scope file: `rm -f .project-orchestrator/scopes/{team-name}.json`
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
