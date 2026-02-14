# Review System v2 — Design & Implementation

## Status: approved

## Design

### Feature Type
Configuration/infra + skill refinement

### Services Affected
- `~/project-orchestrator/` (plugin repo — not a Toraka service)

### Design Details

#### Problem
The parallel Haiku+Sonnet review (v1) is stateless and untracked. It runs two models, merges findings, and presents results — but has no feedback loop limits, no learning from past reviews, no confidence-based auto-decisions, and no analytics to measure review quality. This design adds four interconnected enhancements to create a self-improving review pipeline.

#### Current State (v1)
- `commands/review.md`: parallel model review with 4-category merge (Agreed / Model-B-only / Model-A-only / Contradictions)
- `commands/implement.md` step 8b: primitive fix loop ("send issues to implementer → re-review")
- `agents/spec-reviewer.md` + `agents/quality-reviewer.md`: proper agents with `memory: project`
- Agent memory exists at `.claude/agent-memory/project-orchestrator-{type}/` — spec-reviewer already has review history
- Config: `review.strategy`, `review.parallel_models`, `review.single_model` in `project.yml`

---

### Enhancement 1: Auto-Review Feedback Loop

**Problem:** `implement.md` step 8b says "send issues → re-review after fix" but has no iteration cap, no structured fix-task creation, and no escalation path.

**Design:**

New config:
```yaml
# .claude/project.yml
review:
  max_fix_iterations: 2    # default: 2 — max times implementer can retry before human escalation
  fix_timeout_turns: 10    # default: 10 — max agent turns per fix attempt before escalation
```

Loop flow (replaces implement.md step 8b):
```
for iteration in 1..max_fix_iterations:
  run_review(task)  # parallel or single per strategy
  if PASS:
    mark task reviewed ✅
    break
  else:
    categorize findings:
      critical_count = count(Agreed + Model-B-only findings marked Critical)
      if critical_count == 0 AND only Minor findings:
        mark reviewed ✅ with notes  # minor issues don't block
        break
      SendMessage to implementer:
        "Fix attempt {iteration}/{max}: {specific issues with file:line}"
      wait for implementer completion
      if iteration == max_fix_iterations:
        ESCALATE to human:
          "Task {N} failed review after {max} fix attempts. Remaining issues: {list}"
          pause implementation — don't start dependent tasks
```

**Living state doc update:**
```markdown
| # | Task | Status | Assignee | Spec | Quality | Fix Iterations |
|---|------|--------|----------|------|---------|----------------|
| 1 | ... | complete | impl-1 | ✅ | ✅ | 0 |
| 2 | ... | review-fix-1 | impl-2 | ❌→🔄 | — | 1 |
| 3 | ... | escalated | impl-3 | ❌ | — | 2 (max) |
```

New status values: `review-fix-{N}` (in fix cycle), `escalated` (human needed)

**Files changed:**
- `commands/implement.md` — replace step 8b with loop logic
- `commands/review.md` — add iteration tracking to report output
- `skills/brainstorming/SKILL.md` — add `Fix Iterations` column to task table template

---

### Enhancement 2: Review Memory & Learning

**Problem:** Reviewers have `memory: project` but no structured format. Memory accumulates ad-hoc notes. No way to surface patterns across reviews.

**Design:**

**Memory structure** — each reviewer maintains structured memory at `.claude/agent-memory/project-orchestrator-{type}/`:

```
MEMORY.md              # index + cross-review patterns
reviews/
  {date}-{slug}.md     # per-review findings (already happening organically)
service-patterns/
  {service}.md         # per-service issue patterns (NEW)
```

**Per-service pattern file** (`service-patterns/{service}.md`):
```markdown
# {Service} Review Patterns

## Common Issues
| Pattern | Frequency | Last Seen | Severity | Example |
|---------|-----------|-----------|----------|---------|
| Missing subscribeOn for HTTP calls | 3 | 2026-02-14 | Critical | SeriesMetadataPublisher:95 |
| No error handling on Redis reads | 1 | 2026-02-13 | Important | HomepageService:42 |

## Service-Specific Rules
- Uses reactive patterns — always check TSchedulers.BLOCKING
- R2DBC reads via fluxRead()/monoRead() — flag any direct repo calls
- Caffeine cache TTLs must match CLAUDE.md recommendations

## False Positives to Avoid
| Pattern | Why It's Not an Issue |
|---------|----------------------|
| toBlocking() in Mono.fromCallable | Valid pattern per CLAUDE.md |
| Missing @Transactional | R2DBC doesn't use Spring transactions |
```

**How reviewers use memory:**
1. At review start: read `service-patterns/{target-service}.md` if it exists
2. Weight known-issue patterns higher (look for them first)
3. Avoid known false positives
4. At review end: update service patterns with new findings

**Memory update instruction** (add to reviewer skills):
```
## Post-Review Memory Update
After completing your review, update your memory:
1. Read `service-patterns/{service}.md` (create if missing)
2. For each finding:
   - If pattern already tracked: increment frequency, update last_seen
   - If new pattern: add to Common Issues table
3. If you flagged something and the lead dismissed it: add to False Positives
4. Keep MEMORY.md index updated with review count and key learnings
```

**Memory pruning:** Patterns not seen in 30+ days get moved to an "Archive" section. Keeps active memory focused.

**Files changed:**
- `skills/spec-reviewer/SKILL.md` — add post-review memory update section
- `skills/quality-reviewer/SKILL.md` — add post-review memory update section
- `agents/spec-reviewer.md` — add memory structure to First Steps
- `agents/quality-reviewer.md` — add memory structure to First Steps

---

### Enhancement 3: Speculative Parallel Review + Confidence Scoring

**Problem:** v1 runs spec and quality reviews sequentially (quality waits for spec to pass). The merge strategy has 4 categories but no scoring. Every review requires human attention regardless of confidence level.

**Design:**

#### Speculative Parallel Execution (First Iteration)

On the **first review iteration** of each task, run all 4 reviewers in parallel:
```
┌─────────────────────────────────────────────────┐
│ First review (speculative parallel):            │
│                                                 │
│   Spec-reviewer (haiku)     ─┐                  │
│   Spec-reviewer (sonnet)    ─┤ All 4 in        │
│   Quality-reviewer (haiku)  ─┤ parallel         │
│   Quality-reviewer (sonnet) ─┘                  │
│                                                 │
│ Merge step:                                     │
│   1. Merge spec findings (haiku + sonnet)       │
│   2. If spec PASS → merge quality findings      │
│   3. If spec FAIL → discard quality results     │
└─────────────────────────────────────────────────┘
```

**Why speculative:** Most tasks pass spec review (the common case). Running quality speculatively saves one full review cycle of wall-clock time. The cost of discarding quality results on spec failure is 2 cheap model calls (haiku + sonnet) — negligible.

**On fix iterations (2nd+ review):** Run spec-only first (sequential), then quality if spec passes. Fix iterations are targeted fixes, so spec re-check is the priority. No speculative quality run.

New config:
```yaml
# .claude/project.yml
review:
  speculative_quality: true  # default: true — run quality in parallel with spec on first review
  auto_approve: true         # default: true — auto-approve when both models pass with no critical/important findings
  auto_reject: true          # default: true — auto-send-to-implementer when both agree on critical issues
  # When false: always present to human regardless of confidence
```

#### Confidence Scoring

**Confidence model:**

| Scenario | Confidence | Auto-Action |
|----------|------------|-------------|
| Both models PASS (spec+quality), zero findings | Very High (1.0) | Auto-approve ✅ |
| Both models PASS, minor-only findings | High (0.85) | Auto-approve ✅ with notes |
| Both models FAIL, agreed critical issues | High (0.9) | Auto-reject → fix loop |
| One model PASS, one FAIL | Low (0.4) | Human decides |
| Both FAIL but disagree on which issues | Medium (0.6) | Human decides |
| Model-B-only critical finding | Medium (0.7) | Human decides (stronger model found something) |

**Decision logic** (in review command merge step):
```
def decide(spec_haiku, spec_sonnet, quality_haiku, quality_sonnet):
  # Step 1: Merge spec
  spec_agreed = intersection(spec_haiku.findings, spec_sonnet.findings)
  spec_result = merge(spec_haiku, spec_sonnet)

  if spec_result == FAIL:
    discard(quality_haiku, quality_sonnet)  # speculative results invalid
    if any_critical(spec_agreed) and config.review.auto_reject:
      return AUTO_REJECT_TO_IMPLEMENTER
    return PRESENT_TO_HUMAN

  # Step 2: Spec passed — merge quality
  quality_agreed = intersection(quality_haiku.findings, quality_sonnet.findings)
  quality_result = merge(quality_haiku, quality_sonnet)

  all_findings = spec_result.findings + quality_result.findings
  if not all_findings or all_minor(all_findings):
    if config.review.auto_approve:
      return AUTO_APPROVE
    return PRESENT_TO_HUMAN

  if quality_result == FAIL and any_critical(quality_agreed):
    if config.review.auto_reject:
      return AUTO_REJECT_TO_IMPLEMENTER
    return PRESENT_TO_HUMAN

  return PRESENT_TO_HUMAN
```

**Report format update:**
```markdown
## Review Result — Task {N}

**Strategy:** Speculative parallel (4 reviewers)
**Confidence: Very High (1.0)** — both models passed spec+quality, no findings
**Auto-decision: ✅ Approved** (override with `review.auto_approve: false`)

### Spec Findings
| Category | Count | Severity | Action |
|----------|-------|----------|--------|
| Agreed | 0 | — | — |
| Sonnet-only | 0 | — | — |
| Haiku-only | 0 | — | — |

### Quality Findings
| Category | Count | Severity | Action |
|----------|-------|----------|--------|
| Agreed | 0 | — | — |
| Sonnet-only | 1 | Minor | Noted, not blocking |
| Haiku-only | 0 | — | — |
```

**Files changed:**
- `commands/review.md` — add speculative parallel spawn, confidence scoring, auto-decision logic
- `commands/implement.md` — use speculative parallel + auto-decision in auto-review step (8b)

---

### Enhancement 4: Review Analytics

**Problem:** No way to measure whether the review system is effective. Can't tune model selection or merge strategy without data.

**Design:**

**Storage:** `.claude/review-analytics.json` at the project root — single JSON file, append-only entries.

```json
{
  "reviews": [
    {
      "date": "2026-02-14",
      "feature": "core-standardization",
      "task": 2,
      "service": "toraka-core",
      "strategy": "parallel",
      "models": ["haiku", "sonnet"],
      "stage": "spec",
      "haiku_verdict": "fail",
      "sonnet_verdict": "fail",
      "agreed_count": 1,
      "haiku_only_count": 0,
      "sonnet_only_count": 2,
      "contradiction_count": 0,
      "confidence": 0.9,
      "auto_decision": "auto_reject",
      "human_override": null,
      "fix_iterations": 1,
      "final_verdict": "pass",
      "findings": [
        {
          "id": "f1",
          "description": "Bug count mismatch: 3 vs 4",
          "severity": "critical",
          "category": "agreed",
          "resolution": "fixed",
          "false_positive": false
        }
      ]
    }
  ],
  "summary": {
    "total_reviews": 12,
    "auto_approved": 8,
    "auto_rejected": 2,
    "human_decided": 2,
    "avg_fix_iterations": 0.5,
    "model_accuracy": {
      "haiku": { "true_positive": 15, "false_positive": 3, "missed": 5 },
      "sonnet": { "true_positive": 20, "false_positive": 1, "missed": 2 }
    },
    "by_service": {
      "toraka-core": { "reviews": 6, "common_issues": ["missing subscribeOn", "unconsumed R2DBC"] },
      "frontend": { "reviews": 3, "common_issues": ["missing error states"] }
    }
  }
}
```

**When analytics are updated:**
1. After each review merge → append review entry with findings
2. After fix loop completes → update `fix_iterations` and `final_verdict`
3. After human override → update `human_override` field
4. Summary recalculated on each append (simple counters)

**How analytics inform tuning:**
- If `model_accuracy.haiku.false_positive` is high → consider dropping haiku or switching to single-model
- If `avg_fix_iterations` > 1 → reviewers may be too strict, or implementers need clearer specs
- If a service has high `common_issues` → add to service CLAUDE.md as known patterns
- Present analytics summary when user runs `/project:progress`

**Analytics command** (future — not in this design):
A `/project:analytics` command could render dashboards from this data. Out of scope for v2 — analytics file is the foundation.

**Files changed:**
- `commands/review.md` — write analytics entry after each review
- `commands/implement.md` — write analytics entry after auto-review
- `commands/progress.md` — show analytics summary if file exists

---

### Config Schema (complete v2 additions)

```yaml
# .claude/project.yml — new keys (all optional, sensible defaults)
review:
  # Existing v1 keys (unchanged):
  strategy: parallel             # parallel | single
  parallel_models: [haiku, sonnet]
  single_model: opus

  # NEW v2 keys:
  speculative_quality: true      # run quality in parallel with spec on first review
  max_fix_iterations: 2          # max fix attempts before human escalation
  fix_timeout_turns: 10          # max agent turns per fix attempt
  auto_approve: true             # auto-approve high-confidence passes
  auto_reject: true              # auto-send-to-implementer high-confidence failures
```

Defaults:

| Key | Default | Rationale |
|-----|---------|-----------|
| `review.speculative_quality` | `true` | Saves one review cycle on passing tasks (common case) |
| `review.max_fix_iterations` | `2` | Enough for typos/minor fixes, escalates real issues |
| `review.fix_timeout_turns` | `10` | Prevents infinite agent loops |
| `review.auto_approve` | `false` | Conservative default — human reviews all verdicts until confidence in system builds |
| `review.auto_reject` | `false` | Conservative default — human confirms before sending issues back to implementer |

Validation:

| Rule | Error |
|------|-------|
| `max_fix_iterations` < 1 or > 5 | "max_fix_iterations must be 1-5" |
| `fix_timeout_turns` < 5 or > 30 | "fix_timeout_turns must be 5-30" |

**Speculative quality + single strategy:** When `review.strategy: single` and `speculative_quality: true`, spawn 2 agents total (1 spec + 1 quality) in parallel instead of 4. The speculative pattern still applies — discard quality if spec fails.

---

### Cross-Enhancement Integration

The four enhancements work together:

```
First Review (speculative parallel — E3):
  Spawn 4 agents: spec(haiku), spec(sonnet), quality(haiku), quality(sonnet)
  Wait for all 4 to complete
  Merge spec findings → decide spec verdict
  ├── Spec FAIL → discard quality results
  │     ├── Auto-reject to fix loop (E1 + E3)
  │     │     ├── Implementer fixes
  │     │     ├── Re-review: spec-only sequential (E1)
  │     │     │     └── If spec passes → run quality (not speculative)
  │     │     │     └── If max iterations → escalate to human (E1)
  │     │     └── Write analytics entry per iteration (E4)
  │     │     └── Update reviewer memory with fix patterns (E2)
  │     └── Human decides (if disagreement)
  │           └── Track override in analytics (E4)
  └── Spec PASS → merge quality findings
        ├── All PASS → Auto-approve (E3)
        │     └── Write analytics entry (E4)
        │     └── Update reviewer memory (E2)
        ├── Quality FAIL, agreed → Auto-reject to fix loop (E1 + E3)
        └── Disagreement → Human decides (E3)
              └── Track override in analytics (E4)
              └── If dismissed → add to false positives (E2)
```

**Human override tracking:**
When a human overrides an auto-decision (approves despite issues, or rejects despite pass), the review command should:
1. Record the override in analytics (`human_override` field)
2. Tell the reviewer to add the pattern to false positives (if override = approve) or common issues (if override = reject)

---

## Implementation Tasks

| # | Task | Status | Assignee | Spec | Quality |
|---|------|--------|----------|------|---------|
| 1 | Add speculative 4-parallel review + confidence scoring + auto-decision to review command (E3) | pending | — | — | — |
| 2 | Add fix iteration loop + escalation to implement command (E1) | pending | — | — | — |
| 3 | Add structured memory format to reviewer skills + agents (E2) | pending | — | — | — |
| 4 | Add analytics tracking to review and implement commands (E4) | pending | — | — | — |
| 5 | Add new config keys + validation to brainstorm skill config loading (E1+E3) | pending | — | — | — |
| 6 | Update progress command to show analytics summary (E4) | pending | — | — | — |
| 7 | Add Fix Iterations column to brainstorm skill task table template | pending | — | — | — |
| 8 | Update README.md with v2 config schema and review system docs | pending | — | — | — |

### Dependencies
- Tasks 1, 3, 5: independent (wave 1)
- Task 2: depends on Task 1 (implement uses review's confidence logic)
- Task 4: depends on Tasks 1, 2 (analytics writes after review/fix-loop)
- Task 6: depends on Task 4 (reads analytics file)
- Task 7: independent (template change only, wave 1)
- Task 8: depends on all others (documentation)

### Shared file analysis
- `commands/review.md`: Tasks 1, 4 — **sequence** (1 → 4)
- `commands/implement.md`: Tasks 2, 4 — **sequence** (2 → 4)
- `skills/brainstorming/SKILL.md`: Tasks 5, 7 — **sequence** (5 → 7)
- `skills/spec-reviewer/SKILL.md`: Task 3 only
- `skills/quality-reviewer/SKILL.md`: Task 3 only
- `agents/spec-reviewer.md`: Task 3 only
- `agents/quality-reviewer.md`: Task 3 only
- `commands/progress.md`: Task 6 only
- `README.md`: Task 8 only

### Suggested waves
- **Wave 1:** Tasks 1, 3, 5, 7 (confidence scoring, memory format, config, template — no shared files)
- **Wave 2:** Tasks 2, 4 (fix loop + analytics — sequential within wave due to shared implement.md dependency, but 2 can start before 4)
- **Wave 3:** Tasks 6, 8 (progress analytics + README — no shared files)

## Decisions & Context

- Analytics stored as `.claude/review-analytics.json` at project root — simple, append-only, no MCP dependency
- Memory structured per-service (not per-review) — optimizes for "what patterns does this service have?" queries
- Confidence scoring uses discrete scenarios (not continuous scores) — simpler to reason about, less likely to produce weird edge cases
- Auto-approve/auto-reject are separate booleans — user might want auto-approve but always human-review failures
- Fix iteration cap defaults to 2 — enough for quick fixes, prevents infinite loops on fundamental misunderstandings
- Human override tracking closes the feedback loop — analytics can measure whether auto-decisions are good
- Analytics summary in `/project:progress` — no separate command yet, avoid feature creep
- Memory pruning at 30 days — prevents unbounded growth while keeping recent patterns active
- False positive tracking feeds back into memory — reviewers learn from human overrides
