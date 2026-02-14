---
name: project:review
description: Review completed implementation tasks — parallel spec + quality reviewers
argument-hint: "[plan file path]"
allowed-tools: [Read, Glob, Grep, Task]
---

<objective>
Review orchestrator. Find completed but unreviewed tasks in a design doc and run two-stage review (spec compliance + code quality) on each.
</objective>

<context>
- `$ARGUMENTS` — plan file path (optional, defaults to latest design doc)
</context>

<process>
1. **Load project config** from `.claude/project.yml` (defaults if missing)

2. **Find the design doc**
   - If a plan file path was provided in arguments, use it
   - Otherwise, check `{config.plans_dir}/INDEX.md` for active plans, or find `{config.plans_dir}/*-design.md`
   - If no design doc exists, tell the user: "No design doc found. Nothing to review."

3. **Find unreviewed tasks** — tasks where status is `complete` and Spec column is not `✅`
   - If none exist, tell the user: "All tasks are reviewed. Run `/project:verify` to do final verification."

4. **Run two-stage review per task** (up to 3 concurrent):

   **Stage 1 — Spec compliance:**
   ```
   Task(general-purpose, model: opus):
     Read `.claude/skills/project-orchestrator:spec-reviewer/SKILL.md` or invoke `project-orchestrator:spec-reviewer` skill.
     Task spec: {full task description}
     Implementer report: {from Implementation Log}
     Living state doc: {path}
   ```

   **Stage 2 — Code quality** (only if spec passes):
   ```
   Task(feature-dev:code-reviewer, model: opus):
     Read `.claude/skills/project-orchestrator:quality-reviewer/SKILL.md` or invoke `project-orchestrator:quality-reviewer` skill.
     Task: {title}
     What was implemented: {from report}
     Plan: {path}
   ```

5. **Report results** — update living state doc (Spec/Quality columns), report to user which tasks passed/failed, suggest next steps:
   - Fix issues → `/project:review` again
   - All pass → `/project:verify` then `/project:finish`
</process>

<success_criteria>
- [ ] All completed tasks have been reviewed (spec + quality)
- [ ] Living state doc updated with review results
- [ ] User told which tasks passed/failed and next steps
</success_criteria>
