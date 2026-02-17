---
name: project:review-design
description: Review a design doc before implementation — parallel spec completeness + feasibility reviewers
argument-hint: "[plan file path]"
allowed-tools: [Read, Glob, Grep, Edit, Task, AskUserQuestion]
---

<objective>
Design review orchestrator. Find a design doc and run two-stage review (spec completeness + feasibility) before implementation starts.
</objective>

<context>
- `$ARGUMENTS` — plan file path (optional, defaults to latest design doc)
- Project config: @.project-orchestrator/project.yml
- Plans index: @docs/plans/INDEX.md
</context>

<process>
1. **Parse project config** (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)

2. **Find the design doc**
   - If a plan file path was provided in arguments, use it
   - Otherwise, check `{config.plans_dir}/INDEX.md` for active plans, or find `{config.plans_dir}/*-design.md`
   - If no design doc exists, tell the user: "No design doc found. Nothing to review."
   - If the design doc status is already `reviewed` or `implementing`, tell the user and ask if they want to re-review

3. **Read review config** from `.project-orchestrator/project.yml`:
   - `review.strategy`: `parallel` (default) or `single`
   - `review.parallel_models`: list of exactly 2 models (default: `[haiku, sonnet]`)
   - `review.single_model`: single model (default: `opus`)
   - **Validate:** If `review.parallel_models` doesn't have exactly 2 entries, error: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])"
   - **Validate:** If `review.strategy` is not `parallel` or `single`, error: "review.strategy must be 'parallel' or 'single'"

4. **Collect context for reviewers**
   - Read the design doc in full
   - Identify all files the design proposes to create or modify (from task table and task details)
   - Read existing files that will be modified (for integration context)

5. **Run two-stage review:**

   **When `review.strategy: parallel` (default):**

   **Stage 1 — Spec completeness:**
   Spawn 2 reviewers in parallel using the `design-reviewer` agent:
   ```
   Task(subagent_type: "design-reviewer", model: config.review.parallel_models[0]):
     Design doc: {path}
     Stage: completeness
     Existing files to review (for integration context): {list of existing files proposed for modification}

   Task(subagent_type: "design-reviewer", model: config.review.parallel_models[1]):
     (same prompt)
   ```
   **Merge findings** (lead session does this, not a separate agent):
   | Category | Meaning | Action |
   |----------|---------|--------|
   | Agreed | Both models flagged | High confidence — must address |
   | Model-B-only | Only the stronger model found it | Likely real — review and usually apply |
   | Model-A-only | Only the faster model found it | Review, may be stylistic |
   | Contradictions | Models disagree | Present both, user decides |

   **Stage 2 — Feasibility:**
   Spawn 2 reviewers in parallel (same pattern):
   ```
   Task(subagent_type: "design-reviewer", model: config.review.parallel_models[0]):
     Design doc: {path}
     Stage: feasibility
     Existing files to review (for integration context): {list of existing files proposed for modification}

   Task(subagent_type: "design-reviewer", model: config.review.parallel_models[1]):
     (same prompt)
   ```
   Merge using same category table.

   **When `review.strategy: single`:**

   **Stage 1 — Spec completeness:**
   ```
   Task(subagent_type: "design-reviewer", model: config.review.single_model):
     Design doc: {path}
     Stage: completeness
     Existing files to review (for integration context): {list of existing files proposed for modification}
   ```

   **Stage 2 — Feasibility:**
   ```
   Task(subagent_type: "design-reviewer", model: config.review.single_model):
     Design doc: {path}
     Stage: feasibility
     Existing files to review (for integration context): {list of existing files proposed for modification}
   ```

6. **Report results** — present merged findings to user, update design doc status:
   - If passing (no critical issues): update status to `reviewed`
   - If issues found: present findings, suggest fixes, leave status unchanged
   - Suggest next steps:
     - Fix issues → `/project:review-design` again
     - All pass → `/clear` then `/project:implement`
</process>

<success_criteria>
- [ ] Design doc reviewed for spec completeness and feasibility
- [ ] Findings merged and presented with severity levels
- [ ] Design doc status updated if passing
- [ ] User told next steps
</success_criteria>
