# Orchestrator Implementation Fixes

**Status:** complete
**Created:** 2026-02-16
**Slug:** orchestrator-impl-fixes

## Problem

During a real orchestrator session (single service, 4 tasks, toraka-core), 6 issues were discovered that caused wasted time, partial implementations, and repeated manual intervention. These are all fixable with targeted changes to 3 plugin files.

Source: `toraka-docs/plans/ideas/2026-02-16-orchestrator-implementation-findings.md`

## Design

### Feature Type
Configuration/infra (plugin skill/command improvements)

### Services Affected
- project-orchestrator (this plugin — no external services)

### Design Details

#### Fix 1: Scope file creation fallback — `commands/implement.md` step 6b

**Problem:** When MCP is unavailable, scope file creation is skipped entirely. Agents hit permission prompts on their first Edit/Write, blocking work until the lead manually creates the scope file.

**Solution:** Replace the "skip entirely" fallback with a direct `Write` to `.claude/hooks/scopes/{team-name}.json`. The scope file format is simple JSON — no MCP needed.

**Change to step 6b:**
```
6b. Create scope file for auto-approve hook
   - Extract service names from design doc's "Services Affected"
   - For each service:
     - If config.services exists: look up service.path for the directory
     - If no config: use service name as relative path (monorepo default)
     - If worktrees active (from step 5.5): use worktree paths instead of service paths
   - Build scope JSON matching the hook's expected schema:
     - "shared" array: all service directory paths (relative to project root)
     - Per-agent keys added later when spawning workers (step 7) if task-specific scoping needed
   - Write `.claude/hooks/scopes/{team-name}.json` via Write tool
   - Ensure `.claude/hooks/scopes/` directory exists before writing

   Scope file format (must match scope-protection.sh expectations):
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"]
   }

   Per-agent scoping (optional, added during step 7 if tasks have specific file lists):
   {
     "team": "{team-name}",
     "shared": ["service1/", "service2/"],
     "implement-t1": ["service1/src/specific/path/"],
     "implement-t2": ["service2/src/specific/path/"]
   }
```

**Why:** The MCP path should be the optimization, not the only path. A `Write` call always works. The scope file format matches what `scope-protection.sh` reads: `.shared[]` for team-wide paths and `.[$agent][]` for agent-specific paths.

---

#### Fix 2: Implementer completeness gate — `skills/implementer/SKILL.md`

**Problem:** Agent added 21 of 130 lines then went idle. No mechanism forces the agent to verify completeness before stopping.

**Solution:** Add an explicit completeness verification step after the self-review checklist, before reporting:

**New section after Self-Review Checklist:**
```
## Completeness Verification (before reporting or going idle)

Before marking your task complete or going idle, run this verification:

1. Re-read your task description from the living state doc
2. Run `git diff --stat` to see what you actually changed
3. Compare your changes against EVERY item in the task description
4. If ANY item is missing or incomplete:
   - Continue working — do NOT go idle with partial changes
   - If you're blocked on something specific, send a progress report (see format below)
5. Only proceed to TaskUpdate + SendMessage when ALL items are fully implemented

CRITICAL: Do NOT stop generating output until either:
- Your task is 100% complete (all items implemented), OR
- You have sent a detailed progress message to the lead

If blocked, keep the conversation active — prompt the lead until unblocked or
told to stop. Never go idle silently with partial work.

## Progress Report (when blocked or incomplete)

If you cannot complete your full task, send this via SendMessage BEFORE going idle:

Task: {task number and title}
Status: in-progress (blocked | needs-clarification)

Completed so far:
- {what you finished}

Still missing:
- {what remains from the task description}

Blocking issue:
- {what's stopping you — permission prompt, unclear spec, dependency, etc.}
```

**Note:** Fix 2 (agent-side gate) and Fix 6 (lead-side detection) are complementary — belt and suspenders. Fix 2 ensures agents communicate before going idle; Fix 6 catches cases where agents go idle without following the protocol.

---

#### Fix 3: INDEX.md entry enforcement — `skills/brainstorming/SKILL.md` step 10

**Problem:** Design doc was created without a corresponding INDEX.md entry when `plans_structure` is `standard`.

**Current:** Step 10 already says "If `config.plans_structure` is `standard`: add entry to `{config.plans_dir}/INDEX.md` under 'Active'". This is correct but lacks specifics.

**Solution:** Add the INDEX.md entry format and creation template to step 10:

```
- If config.plans_structure is `standard`: add entry to {config.plans_dir}/INDEX.md under "## Active"
  Format: `- [{Feature Name}]({filename}) — {one-line summary}`
  Example: `- [Orchestrator Fixes](2026-02-16-orchestrator-impl-fixes-design.md) — Improve agent completeness gates and task messaging`

  If INDEX.md doesn't exist, create it with this structure:
    # Plans Index

    ## Active
    - [{Feature Name}]({filename}) — {one-line summary}

    ## Completed

    ## Backlog

    ## Ideas

  If "## Active" section exists, add the entry at the top of that section (newest first).
```

**Why:** The instruction exists but without a format and template, agents may skip it or produce inconsistent entries. Making it explicit reduces ambiguity.

---

#### Fix 4: Clarify state file and team creation error handling — `commands/implement.md` steps 6/6a

**Problem:** The current step 6/6a error handling is vague. If TeamCreate fails after writing the state file, the cleanup instruction ("delete the state file") is easy to forget.

**Solution:** Keep the original ordering (state file first, team creation second) but make error handling explicit. The original ordering is correct — it avoids a race condition where implementer agents make their first tool call (triggering hooks that read the state file) before the state file exists.

**Updated steps with explicit error matrix:**
```
6. Write orchestrator state file
   - Ensure .claude/ directory exists before writing
   - Write `.claude/orchestrator-state.json` with: active_plan, slug, team, started, worktrees
   - Atomic write via temp file then mv
   - If write fails: report error, exit (no cleanup needed — team doesn't exist yet)

6a. Create implementation team
   TeamCreate("implement-{slug}")
   - If TeamCreate fails:
     - Delete `.claude/orchestrator-state.json` (clean up the state file from step 6)
     - Leave `.claude/` directory intact (may be used by other hooks/state)
     - Report error to user, exit
```

**Why the original ordering is kept:** Implementer agents can make tool calls (triggering PreToolUse hooks that read the state file) very quickly after TeamCreate returns. Writing the state file first guarantees it exists before any hook fires. The race condition from swapping the order is worse than the cleanup-on-error pattern.

---

#### Fix 5: Task assignment messaging pattern — `commands/implement.md` step 8

**Problem:** When the lead combines "task done ack + new task assignment" in one message, agents only process the ack and miss the new assignment. This happened 3 times in one session.

**Root cause:** Agent compaction or message ordering drops the "new task" portion. The agent sees acknowledgment of its previous report and responds to that.

**Solution:** Add explicit messaging discipline to step 8:

```
8. Handle task completion — when an implementer reports via SendMessage:
   - Update living state doc — mark task as complete, log implementer report
   - Check if blocked tasks are now unblocked, start next wave
   - IMPORTANT: Task assignment messaging rules:
     a) Never combine "task done ack" + "new task assignment" in one SendMessage call
     b) Skip the acknowledgment entirely — just send the new task assignment
     c) Include the full task description from TaskGet({task-id}).description
     d) Format (single SendMessage call, no preceding ack):
        "TASK #{N}: {task title}
         {full task description}"
     e) When starting a new wave: send individual task assignments (one SendMessage per agent)
     f) If no more tasks for this agent, send shutdown request

   WRONG — combined ack + assignment in one message:
     SendMessage("Task 1 done, good work. Now do Task 2: ...")

   WRONG — ack followed by assignment as separate messages:
     SendMessage("Task 1 confirmed.")
     SendMessage("Now do Task 2: ...")

   RIGHT — assignment only, no ack:
     SendMessage("TASK #2: Add retry logic to R2dbcSupport\n{full description}")
```

**Why:** The agent doesn't need confirmation that its previous task was received. Skipping the ack and sending only the new assignment eliminates the message-crossing pattern.

**Caveat:** This is a behavioral workaround for message loss during agent compaction. It reduces the likelihood of missed assignments but doesn't prevent compaction-induced message loss entirely. If the pattern recurs despite this discipline, the root cause is in the agent messaging infrastructure and requires an architectural fix.

---

#### Fix 6: Lead idle detection for incomplete work — `commands/implement.md` step 8

**Problem:** Agent went idle with only 21 of 130 lines written. The lead had no mechanism to detect this automatically.

**Solution:** Add idle detection guidance to step 8:

```
   - When an implementer goes idle WITHOUT sending a completion report:
     a) Check git diff --stat in the service directory
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
```

**Why:** Complements Fix 2 (implementer-side gate) with lead-side detection. Fix 2 ensures agents communicate before going idle; Fix 6 catches cases where agents go idle without following the protocol.

---

## Implementation Tasks

| # | Task | File | Status | Assignee | Spec | Quality | Fix Iterations |
|---|------|------|--------|----------|------|---------|----------------|
| 1 | Add scope file creation fallback to step 6b | `commands/implement.md` | pending | — | — | — | — |
| 2 | Add completeness verification gate | `skills/implementer/SKILL.md` | pending | — | — | — | — |
| 3 | Add INDEX.md entry format to step 10 | `skills/brainstorming/SKILL.md` | pending | — | — | — | — |
| 4 | Swap steps 6 and 6a ordering | `commands/implement.md` | pending | — | — | — | — |
| 5 | Add task assignment messaging discipline to step 8 | `commands/implement.md` | pending | — | — | — | — |
| 6 | Add lead idle detection to step 8 | `commands/implement.md` | pending | — | — | — | — |

**Dependencies:** Tasks 1, 4, 5, 6 all edit `commands/implement.md` — must be sequenced or combined into one task.

**Recommended approach:** Combine tasks 1, 4, 5, 6 into a single task (all target `commands/implement.md`). Tasks 2 and 3 are independent.

**Revised task plan:**

| # | Task | File | Status | Assignee | Spec | Quality | Fix Iterations |
|---|------|------|--------|----------|------|---------|----------------|
| 1 | Apply fixes 1, 4, 5, 6 to implement command | `commands/implement.md` | complete | implement-t1 | ✅ | ✅ | 0 |
| 2 | Add completeness verification gate | `skills/implementer/SKILL.md` | complete | implement-t2 | ✅ | ✅ | 0 |
| 3 | Add INDEX.md entry format to step 10 | `skills/brainstorming/SKILL.md` | complete | implement-t3 | ✅ | ✅ | 0 |

**Wave plan:** All 3 tasks target different files — can run in parallel (wave 1).

## Decisions & Context

- **Team-based coordination retained** — considered cmux-style independent agents (each in own worktree, no messaging) but decided to fix messaging patterns instead. Less disruptive, addresses root cause.
- **Scope file format matches existing hook** — uses `shared` + `{agent-name}` schema that `scope-protection.sh` already reads via jq (`.shared[]` and `.[$agent][]`). Earlier draft used a `write_paths`/`bash_allow` format that didn't match — caught in design review.
- **Fix 4 ordering kept as-is** — design review identified a race condition if steps were swapped: implementer agents can make tool calls (triggering hooks that read state file) before the state file would be written. Original ordering (state file first, team second) is safer despite the cleanup-on-error pattern.
- **Fix 5 root cause** — message-crossing is an inherent limitation of the SendMessage model with agent compaction. The fix is behavioral (messaging discipline) rather than architectural. If compaction drops messages entirely, this workaround won't prevent recurrence — noted as a caveat.
- **Fix 2 + Fix 6 are complementary** — agent-side completeness gate (Fix 2) and lead-side idle detection (Fix 6) form belt-and-suspenders. Neither is sufficient alone: agents may skip the protocol (Fix 2 fails), or the lead may misjudge completeness (Fix 6 fails). Together they provide reasonable coverage.
