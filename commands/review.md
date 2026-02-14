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

4. **Read review config** from `.claude/project.yml`:
   - `review.strategy`: `parallel` (default) or `single`
   - `review.parallel_models`: list of exactly 2 models (default: `[haiku, sonnet]`)
   - `review.single_model`: single model (default: `opus`)
   - **Validate:** If `review.parallel_models` doesn't have exactly 2 entries, error: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])"
   - **Validate:** If `review.strategy` is not `parallel` or `single`, error: "review.strategy must be 'parallel' or 'single'"

5. **Run two-stage review per task** (up to 3 concurrent):

   **When `review.strategy: parallel` (default):**

   **Stage 1 — Spec compliance:**
   Spawn 2 reviewers in parallel:
   ```
   Task(spec-reviewer, model: config.review.parallel_models[0]):
     Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md
     Task spec: {full task description}
     Implementer report: {from Implementation Log}
     Living state doc: {path}

   Task(spec-reviewer, model: config.review.parallel_models[1]):
     (same prompt)
   ```
   **Merge findings** (lead session does this, not a separate agent):
   | Category | Meaning | Action |
   |----------|---------|--------|
   | Agreed | Both models flagged | High confidence — must address |
   | Model-B-only | Only the stronger model found it | Likely real — review and usually apply |
   | Model-A-only | Only the faster model found it | Often structural/organizational — review, may be stylistic |
   | Contradictions | Models disagree | Present both arguments, human decides |

   **Stage 2 — Quality** (only if spec passes):
   Same parallel spawn + merge pattern using `quality-reviewer` agent type:
   ```
   Task(quality-reviewer, model: config.review.parallel_models[0]):
     Read ~/project-orchestrator/skills/quality-reviewer/SKILL.md
     Task: {title}
     What was implemented: {from report}
     Plan: {path}

   Task(quality-reviewer, model: config.review.parallel_models[1]):
     (same prompt)
   ```
   Merge using same category table.

   **When `review.strategy: single`:**

   **Stage 1 — Spec compliance:**
   ```
   Task(spec-reviewer, model: config.review.single_model):
     Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md
     Task spec: {full task description}
     Implementer report: {from Implementation Log}
     Living state doc: {path}
   ```

   **Stage 2 — Quality** (only if spec passes):
   ```
   Task(quality-reviewer, model: config.review.single_model):
     Read ~/project-orchestrator/skills/quality-reviewer/SKILL.md
     Task: {title}
     What was implemented: {from report}
     Plan: {path}
   ```

6. **Report results** — update living state doc (Spec/Quality columns), report to user which tasks passed/failed, suggest next steps:
   - Fix issues → `/project:review` again
   - All pass → `/project:verify` then `/project:finish`
</process>

<success_criteria>
- [ ] All completed tasks have been reviewed (spec + quality)
- [ ] Living state doc updated with review results
- [ ] User told which tasks passed/failed and next steps
</success_criteria>
