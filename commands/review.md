---
name: project:review
description: Review completed implementation tasks — speculative parallel review with confidence scoring
argument-hint: "[plan file path]"
allowed-tools: [Read, Glob, Grep, Task]
---

<objective>
Review orchestrator. Find completed but unreviewed tasks in a design doc and run speculative parallel review (spec + quality in parallel) with confidence scoring and auto-decisions.
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
   - `review.speculative_quality`: boolean (default: `true`) — run quality in parallel with spec on first review
   - `review.auto_approve`: boolean (default: `false`) — auto-approve when both models pass with no critical/important findings
   - `review.auto_reject`: boolean (default: `false`) — auto-send-to-implementer when both models agree on critical issues
   - **Validate:** If `review.parallel_models` doesn't have exactly 2 entries, error: "parallel_models requires exactly 2 models (e.g., [haiku, sonnet])"
   - **Validate:** If `review.strategy` is not `parallel` or `single`, error: "review.strategy must be 'parallel' or 'single'"

5. **Run review per task** (up to 3 concurrent). Behavior depends on strategy and whether this is a first review or a fix-iteration re-review.

   ---

   ### First review (speculative parallel)

   On the **first review** of a task (not a fix-iteration re-review), run spec and quality speculatively in parallel.

   **When `review.strategy: parallel` (default) + `speculative_quality: true` (default):**

   Spawn all 4 reviewers in parallel:
   ```
   Task(spec-reviewer, model: config.review.parallel_models[0]):
     Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md
     Task spec: {full task description}
     Implementer report: {from Implementation Log}
     Living state doc: {path}

   Task(spec-reviewer, model: config.review.parallel_models[1]):
     (same prompt)

   Task(quality-reviewer, model: config.review.parallel_models[0]):
     Read ~/project-orchestrator/skills/quality-reviewer/SKILL.md
     Task: {title}
     What was implemented: {from report}
     Plan: {path}

   Task(quality-reviewer, model: config.review.parallel_models[1]):
     (same prompt)
   ```

   **When `review.strategy: single` + `speculative_quality: true`:**

   Spawn 2 reviewers in parallel (1 spec + 1 quality):
   ```
   Task(spec-reviewer, model: config.review.single_model):
     Read ~/project-orchestrator/skills/spec-reviewer/SKILL.md
     Task spec: {full task description}
     Implementer report: {from Implementation Log}
     Living state doc: {path}

   Task(quality-reviewer, model: config.review.single_model):
     Read ~/project-orchestrator/skills/quality-reviewer/SKILL.md
     Task: {title}
     What was implemented: {from report}
     Plan: {path}
   ```

   **When `speculative_quality: false`:**

   Fall back to sequential two-stage review (run spec first, then quality only if spec passes). Use the parallel or single spawn pattern from above for each stage independently.

   ---

   ### Fix-iteration re-review (non-speculative)

   On fix iterations (2nd+ review after implementer fixes), always run **spec-only first** (sequential). If spec passes, then run quality. No speculative quality run — fix iterations are targeted, so spec re-check is the priority.

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

   **Step 2 — Handle quality results based on spec verdict:**
   - If spec **FAIL**: discard all quality results (speculative results are invalid when spec fails)
   - If spec **PASS**: merge quality findings using the same category table

   ---

   ### Confidence scoring

   After merging, compute a confidence score based on these discrete scenarios:

   | Scenario | Confidence | Value |
   |----------|------------|-------|
   | Both stages PASS, zero findings | Very High | 1.0 |
   | Both stages PASS, minor-only findings | High | 0.85 |
   | Both stages FAIL, models agree on critical issues | High | 0.9 |
   | One model PASS, one FAIL (within a stage) | Low | 0.4 |
   | Both FAIL but disagree on which issues are critical | Medium | 0.6 |
   | Model-B-only critical finding (stronger model found something weaker missed) | Medium | 0.7 |

   For `single` strategy: confidence is based on the single model's verdict only. Both-PASS with no findings = Very High (1.0), PASS with minor findings = High (0.85), FAIL with critical = High (0.9). No model-agreement scenarios apply.

   ---

   ### Auto-decision logic

   After computing confidence, apply auto-decision rules:

   ```
   # Determine auto-decision
   if spec_verdict == FAIL:
     if has_agreed_critical_findings(spec) AND config.review.auto_reject:
       decision = AUTO_REJECT  # send back to implementer
     else:
       decision = HUMAN_DECIDES

   else:  # spec PASS
     all_findings = spec_findings + quality_findings
     if no_findings(all_findings) OR all_minor(all_findings):
       if config.review.auto_approve:
         decision = AUTO_APPROVE
       else:
         decision = HUMAN_DECIDES
     elif quality_verdict == FAIL AND has_agreed_critical_findings(quality):
       if config.review.auto_reject:
         decision = AUTO_REJECT  # send back to implementer
       else:
         decision = HUMAN_DECIDES
     else:
       decision = HUMAN_DECIDES
   ```

   **AUTO_APPROVE**: Mark task as reviewed (Spec ✅, Quality ✅), report to user with confidence score.
   **AUTO_REJECT**: Report findings and indicate task will be sent back to implementer for fixes (used by implement command's fix loop).
   **HUMAN_DECIDES**: Present full report with findings and confidence score, wait for user decision.

   ---

6. **Report results** using this format per task:

   ```markdown
   ## Review Result — Task {N}

   **Strategy:** {Speculative parallel (4 reviewers) | Speculative parallel (2 reviewers, single model) | Sequential (parallel models) | Sequential (single model)}
   **Confidence: {Very High|High|Medium|Low} ({score})** — {reason}
   **Auto-decision: {✅ Approved | ❌ Rejected → fix loop | ⏸ Human decides}** {override hint if auto}

   ### Spec Findings
   | Category | Count | Severity | Details |
   |----------|-------|----------|---------|
   | Agreed | {n} | {severity} | {summary} |
   | Sonnet-only | {n} | {severity} | {summary} |
   | Haiku-only | {n} | {severity} | {summary} |

   ### Quality Findings
   | Category | Count | Severity | Details |
   |----------|-------|----------|---------|
   | Agreed | {n} | {severity} | {summary} |
   | Sonnet-only | {n} | {severity} | {summary} |
   | Haiku-only | {n} | {severity} | {summary} |

   _(Quality findings omitted — spec failed, speculative results discarded)_
   ```

   For `single` strategy, omit category columns (no model comparison) and show findings as a flat list.

   After reporting, **update living state doc** (Spec/Quality columns) and suggest next steps:
   - AUTO_APPROVE: "Task {N} auto-approved with {confidence}. Override with `review.auto_approve: false`."
   - AUTO_REJECT: "Task {N} auto-rejected — {count} critical findings. Sending to implementer for fixes."
   - HUMAN_DECIDES: "Review the findings above and decide: approve, reject to fix loop, or dismiss specific findings."
   - All tasks done → `/project:verify` then `/project:finish`

7. **Write analytics entry** — after each review merge, append an entry to `.claude/review-analytics.json` at the consumer project root.

   **Read the existing file** (create with `{"reviews": [], "summary": {}}` if missing), then append a review entry:

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
     "fix_iterations": 0,
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

   For `single` strategy: set `models` to `["{single_model}"]`, set `haiku_verdict`/`sonnet_verdict` to the single model's verdict (both the same), and set `haiku_only_count`/`sonnet_only_count`/`contradiction_count` to 0.

   **Recalculate summary counters** after appending:
   ```json
   {
     "total_reviews": "{count of all entries in reviews array}",
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
         "common_issues": ["{top recurring finding descriptions for this service}"]
       }
     }
   }
   ```

   **Model accuracy tracking:** Update `model_accuracy` when `human_override` is set (not on initial write — accuracy is only knowable after human feedback). When a human overrides:
   - Override approves (auto_reject overridden): findings that were auto_reject triggers become `false_positive` for the models that flagged them
   - Override rejects (auto_approve overridden): `missed` increments for models that didn't flag the issue
   - Findings confirmed by human: `true_positive` increments for models that flagged them

   **Human override update:** When a human overrides an auto-decision, update the corresponding review entry's `human_override` field to `"approve"` or `"reject"`, update finding resolutions, recalculate `model_accuracy`, and recalculate summary counters.

   Write the updated JSON back to `.claude/review-analytics.json`.
</process>

<success_criteria>
- [ ] All completed tasks have been reviewed (spec + quality, or spec-only if spec failed)
- [ ] Speculative parallel execution used on first review iteration (4 agents for parallel strategy, 2 for single)
- [ ] Confidence score computed and reported for each task
- [ ] Auto-decisions applied when enabled and confidence is sufficient
- [ ] Living state doc updated with review results
- [ ] User told which tasks passed/failed, confidence scores, and next steps
- [ ] Analytics entry written to `.claude/review-analytics.json` after each review merge
- [ ] Summary counters recalculated after each append
</success_criteria>
