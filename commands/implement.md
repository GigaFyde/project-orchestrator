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
   - Extract `review.speculative_quality` (default: true), `review.auto_approve` (default: false), `review.auto_reject` (default: false) for auto-decisions
   - Extract `review.max_fix_iterations` (default: 2), `review.fix_timeout_turns` (default: 10) for fix loop
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
   - b) **Auto-review with fix iteration loop** (if auto-review enabled):

     Read config values:
     - `review.max_fix_iterations` (default: 2) — max fix attempts before escalation
     - `review.fix_timeout_turns` (default: 10) — max agent turns per fix attempt
     - `review.strategy`, `review.parallel_models`, `review.single_model`, `review.speculative_quality`, `review.auto_approve`, `review.auto_reject` — see `/project:review` for full config

     ```
     for iteration in 1..max_fix_iterations:

       ### Run review (iteration-aware)

       if iteration == 1:
         # First review — speculative parallel (run spec + quality in parallel)
         # Follow the "First review (speculative parallel)" pattern from /project:review:
         #   parallel strategy + speculative: spawn 4 agents (spec×2 models + quality×2 models)
         #   single strategy + speculative: spawn 2 agents (1 spec + 1 quality)
         #   speculative_quality: false: sequential two-stage (spec first, quality if spec passes)
         run_review(task, speculative=true)

       else:
         # Fix iteration (2nd+) — non-speculative, spec-first sequential
         # Run spec-only first. If spec passes, then run quality.
         # No speculative quality run — fix iterations are targeted, spec re-check is priority.
         run_review(task, speculative=false)

       ### Merge findings and compute confidence
       # Use the same merge step, confidence scoring, and auto-decision logic from /project:review

       ### Evaluate review result

       if decision == AUTO_APPROVE:
         mark task reviewed ✅ (Spec ✅, Quality ✅)
         update Fix Iterations column to {iteration - 1}
         break

       if decision == HUMAN_DECIDES:
         # Minor-only findings — don't block
         all_findings = spec_findings + quality_findings
         if all findings are Minor severity only:
           mark task reviewed ✅ with notes (Spec ✅, Quality ✅)
           update Fix Iterations column to {iteration - 1}
           log minor findings as notes in living state doc
           break
         # Non-minor findings needing human input — escalate immediately
         update task status to "escalated" in living state doc
         update Fix Iterations column to {iteration - 1}
         report to user:
           "Task {N} needs human review — {reason}. Confidence: {score}."
           "Review findings and decide: approve, reject to fix loop, or dismiss."
         pause dependent tasks — do NOT start tasks that depend on this one
         break

       if decision == AUTO_REJECT:
         if iteration == max_fix_iterations:
           # Max iterations reached — escalate to human
           update task status to "escalated" in living state doc
           update Fix Iterations column to {iteration} (max)
           report to user:
             "Task {N} failed review after {max_fix_iterations} fix attempts."
             "Remaining issues: {list of critical findings with file:line refs}"
           pause dependent tasks — do NOT start tasks that depend on this one
           break

         # Send back to implementer for fixes
         update task status to "review-fix-{iteration}" in living state doc
         update Fix Iterations column to {iteration}
         SendMessage to implementer agent:
           "Fix attempt {iteration}/{max_fix_iterations}: Review found issues that must be fixed."
           "Issues:" (include specific findings with file:line references)
           "You have {fix_timeout_turns} turns to fix these issues."
         wait for implementer to report completion
         # Loop continues to next iteration (re-review)
     ```

   - c) **Write analytics entry** after each review iteration — append to `.claude/review-analytics.json` at the consumer project root.

     Read the existing file (create with `{"reviews": [], "summary": {}}` if missing), then append a review entry:

     ```json
     {
       "date": "{YYYY-MM-DD}",
       "feature": "{feature slug from design doc}",
       "task": {task number},
       "service": "{service name from task table}",
       "strategy": "{parallel|single}",
       "models": ["{model-a}", "{model-b}"],
       "stage": "{spec|quality|both}",
       "haiku_verdict": "{pass|fail}",
       "sonnet_verdict": "{pass|fail}",
       "agreed_count": {n},
       "haiku_only_count": {n},
       "sonnet_only_count": {n},
       "contradiction_count": {n},
       "confidence": {score},
       "auto_decision": "{auto_approve|auto_reject|human_decides}",
       "human_override": null,
       "fix_iterations": {current iteration - 1},
       "final_verdict": "{pass|fail|pending}",
       "findings": [
         {
           "id": "f{n}",
           "description": "{finding description}",
           "severity": "{critical|important|minor}",
           "category": "{agreed|sonnet_only|haiku_only|contradiction}",
           "resolution": "{pending|fixed|dismissed}",
           "false_positive": false
         }
       ]
     }
     ```

     For `single` strategy: set `models` to `["{single_model}"]`, set both verdict fields to the single model's verdict, and set model-specific counts to 0.

     **After fix loop completes** (task passes review or is escalated): update the **most recent analytics entry for this task** with:
     - `fix_iterations`: total number of fix iterations performed
     - `final_verdict`: `"pass"` if task passed review, `"fail"` if escalated

     **After human override** (escalation where human approves or rejects): update the corresponding review entry's `human_override` field to `"approve"` or `"reject"`.

     **Recalculate summary counters** after each write:
     ```json
     {
       "total_reviews": "{count of all entries}",
       "auto_approved": "{count where auto_decision == 'auto_approve'}",
       "auto_rejected": "{count where auto_decision == 'auto_reject'}",
       "human_decided": "{count where auto_decision == 'human_decides'}",
       "avg_fix_iterations": "{average of fix_iterations across all entries}",
       "model_accuracy": {
         "haiku": { "true_positive": 0, "false_positive": 0, "missed": 0 },
         "sonnet": { "true_positive": 0, "false_positive": 0, "missed": 0 }
       },
       "by_service": {
         "{service}": {
           "reviews": "{count for this service}",
           "common_issues": ["{top recurring finding descriptions}"]
         }
       }
     }
     ```

     Write the updated JSON back to `.claude/review-analytics.json`.

   - d) Update living state doc with review results — use these status values:
     - `review-fix-{N}`: task is in fix cycle, iteration N
     - `escalated`: task needs human intervention (max iterations reached or human-decides with non-minor findings)
     - `complete` with Spec ✅ / Quality ✅: task passed review

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
- [ ] Reviews passed or escalated (if auto-review enabled)
- [ ] Fix iteration loop respected max_fix_iterations with proper escalation
- [ ] Escalated tasks reported to user with remaining issues
- [ ] Analytics entry written to `.claude/review-analytics.json` after each review iteration
- [ ] Analytics updated with fix_iterations and final_verdict after fix loop completes
- [ ] Analytics updated with human_override after escalation resolution
- [ ] Summary counters recalculated after each analytics write
- [ ] Living state doc updated with final status
- [ ] Team cleaned up via TeamDelete
- [ ] User told next steps (`/project:verify`, `/project:finish`)
</success_criteria>
