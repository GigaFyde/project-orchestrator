---
name: project:review
description: Review implementation against design doc — holistic diff-based spec + quality review
argument-hint: "[plan file path]"
allowed-tools: [Read, Glob, Grep, Bash, Edit, Write, Task, AskUserQuestion]
---

<objective>
Review the full implementation diff against its design doc. Run spec + quality reviewers in parallel, merge findings with confidence scoring, and offer to fix egregious issues (with user approval).
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

3. **Gather the implementation diff**
   - Determine the base branch from `config.services[name].branch` (default: `main`)
   - Get the full diff: `git diff {base-branch}...HEAD` (or `git diff HEAD` if on the same branch with uncommitted changes)
   - Also get `git diff --stat` for the file-level summary
   - If no diff found, tell the user: "No changes to review."

4. **Read review config** from `.project-orchestrator/project.yml`:
   - `review.strategy`: `parallel` (default) or `single`
   - `review.parallel_models`: list of exactly 2 models (default: `[haiku, sonnet]`)
   - `review.single_model`: single model (default: `opus`)
   - **Validate:** If `review.parallel_models` doesn't have exactly 2 entries, error: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])"
   - **Validate:** If `review.strategy` is not `parallel` or `single`, error: "review.strategy must be 'parallel' or 'single'"

5. **Run holistic review** — spawn spec + quality reviewers in parallel against the full diff.

   **When `review.strategy: parallel` (default):**

   Spawn all 4 reviewers in parallel:
   ```
   Task(spec-reviewer, model: config.review.parallel_models[0]):
     Design doc: {path}
     Full diff: {git diff output}
     Changed files: {git diff --stat}
     Review the ENTIRE implementation against the design doc spec.
     Check: missing requirements, extras beyond spec, misunderstandings.

   Task(spec-reviewer, model: config.review.parallel_models[1]):
     (same prompt)

   Task(quality-reviewer, model: config.review.parallel_models[0]):
     Design doc: {path}
     Full diff: {git diff output}
     Changed files: {git diff --stat}
     Review the ENTIRE implementation for code quality.

   Task(quality-reviewer, model: config.review.parallel_models[1]):
     (same prompt)
   ```

   **When `review.strategy: single`:**

   Spawn 2 reviewers in parallel:
   ```
   Task(spec-reviewer, model: config.review.single_model):
     (same prompt as above)

   Task(quality-reviewer, model: config.review.single_model):
     (same prompt as above)
   ```

   ---

   ### Merge step (lead session does this, not a separate agent)

   **Step 1 — Merge spec findings:**

   For `parallel` strategy, categorize findings from both spec reviewers:
   | Category | Meaning | Action |
   |----------|---------|--------|
   | Agreed | Both models flagged | High confidence — must address |
   | Model-B-only | Only the stronger model found it | Likely real — review and usually apply |
   | Model-A-only | Only the faster model found it | Often structural/organizational — review, may be stylistic |
   | Contradictions | Models disagree | Present both arguments, human decides |

   For `single` strategy, take the single model's findings directly (no merge needed).

   Determine spec verdict: **PASS** if no Critical or Important findings in Agreed or Model-B-only categories. **FAIL** otherwise.

   **Step 2 — Merge quality findings:**
   - If spec **FAIL**: discard all quality results (spec issues must be fixed first)
   - If spec **PASS**: merge quality findings using the same category table

   ---

   ### Confidence scoring

   After merging, compute a confidence score:

   | Scenario | Confidence | Value |
   |----------|------------|-------|
   | Both stages PASS, zero findings | Very High | 1.0 |
   | Both stages PASS, minor-only findings | High | 0.85 |
   | Both stages FAIL, models agree on critical issues | High | 0.9 |
   | One model PASS, one FAIL (within a stage) | Low | 0.4 |
   | Both FAIL but disagree on which issues are critical | Medium | 0.6 |
   | Model-B-only critical finding | Medium | 0.7 |

   For `single` strategy: no model-agreement scenarios. PASS with no findings = Very High (1.0), PASS with minor = High (0.85), FAIL with critical = High (0.9).

   ---

6. **Report results:**

   ```markdown
   ## Review Result

   **Strategy:** {Parallel (4 reviewers) | Single (2 reviewers)}
   **Confidence: {Very High|High|Medium|Low} ({score})** — {reason}
   **Verdict: {✅ Pass | ❌ Issues found}**

   ### Spec Findings
   | Category | Severity | Details |
   |----------|----------|---------|
   | Agreed | {severity} | {summary with file:line} |
   | Sonnet-only | {severity} | {summary with file:line} |
   | Haiku-only | {severity} | {summary with file:line} |

   ### Quality Findings
   | Category | Severity | Details |
   |----------|----------|---------|
   | Agreed | {severity} | {summary with file:line} |
   | Sonnet-only | {severity} | {summary with file:line} |
   | Haiku-only | {severity} | {summary with file:line} |
   ```

   For `single` strategy, show findings as a flat list (no category columns).

7. **Handle findings:**

   - **No findings / minor-only:** Report clean review, update living state doc, suggest `/project:verify` → `/project:finish`
   - **Egregious / clear issues** (agreed critical findings with obvious fixes): Offer to fix them automatically:
     "Found {n} clear issues. Want me to fix these? [list of proposed fixes]"
     Wait for user approval before making any changes. After fixing, re-run review on the changed files.
   - **Ambiguous / complex issues:** Present findings and let user decide how to handle them.
     "Found {n} issues that need your input. [details]"

8. **Update living state doc** — update Spec/Quality columns for all tasks based on holistic review result.
   Suggest next steps: `/project:verify` then `/project:finish`

9. **Write analytics entry** — append to `.project-orchestrator/review-analytics.json` at the consumer project root.

   Read the existing file (create with `{"reviews": [], "summary": {}}` if missing), then append:

   ```json
   {
     "date": "{YYYY-MM-DD}",
     "feature": "{feature slug}",
     "service": "{service name}",
     "strategy": "{parallel|single}",
     "models": ["{model-a}", "{model-b}"],
     "spec_verdict": "{pass|fail}",
     "quality_verdict": "{pass|fail}",
     "confidence": {score},
     "finding_count": {n},
     "critical_count": {n},
     "auto_fixed": {n},
     "human_decided": {n},
     "findings": [
       {
         "id": "f{n}",
         "description": "{description}",
         "severity": "{critical|important|minor}",
         "category": "{agreed|model_b_only|model_a_only|contradiction}",
         "resolution": "{fixed|dismissed|pending}",
         "false_positive": false
       }
     ]
   }
   ```

   For `single` strategy: set `models` to `["{single_model}"]`.

   **Recalculate summary counters** after appending:
   ```json
   {
     "total_reviews": {n},
     "by_service": {
       "{service}": { "reviews": {n}, "common_issues": ["{patterns}"] }
     },
     "model_accuracy": {
       "{model}": { "true_positive": 0, "false_positive": 0, "missed": 0 }
     }
   }
   ```

   **Model accuracy tracking:** Update when findings are resolved (fixed = true_positive, dismissed = false_positive for the model that flagged it).

   Write the updated JSON back to `.project-orchestrator/review-analytics.json`.
</process>

<success_criteria>
- [ ] Full implementation diff reviewed holistically (not per-task)
- [ ] Spec + quality reviewers run in parallel per strategy
- [ ] Confidence score computed and reported
- [ ] Egregious issues offered for auto-fix (with user approval)
- [ ] Ambiguous issues presented for user decision
- [ ] Living state doc updated with review results
- [ ] Analytics entry written to `.project-orchestrator/review-analytics.json`
- [ ] User told next steps (`/project:verify`, `/project:finish`)
</success_criteria>
