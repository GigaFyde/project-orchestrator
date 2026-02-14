# Git Worktree Support — Design & Implementation

## Status: complete

## Problem

When two design docs are approved for the same project and both affect overlapping services, they can't be implemented in parallel. The second `/project:implement` would conflict with the first — both sessions editing the same files on the same branch.

Git worktrees solve this by giving each plan its own isolated working copy of the repository, sharing the same `.git` directory. Each plan works on its own branch in its own directory, and they merge sequentially when done.

## Design

### Feature Type
Cross-cutting plugin enhancement (affects commands, skills, config)

### Services Affected
project-orchestrator plugin only (skills, commands, config schema)

### How It Works

```
Session 1: /project:implement plan-A
  → No active plans on overlapping services
  → Works in main working tree as normal

Session 2: /project:implement plan-B
  → Detects plan-A is "implementing" on overlapping services
  → Offers worktree: "Plan A is in-progress on [backend, frontend]. Create a worktree?"
  → User confirms → creates worktree → all implementer agents work in worktree path
  → Living state doc records worktree_path

Session 1 finishes first:
  → /project:finish → PR → merge to main

Session 2 finishes second:
  → /project:finish detects worktree → rebase onto main → PR → merge
  → Worktree cleaned up
```

### Overlap Detection

The implement command already parses the design doc (step 5) and knows which services are affected. Overlap detection runs **after** parsing — inserted as step 5.5 (not 4.5, since it needs the parsed service list):

1. Scan `{plans_dir}/` for other design docs with status `implementing`
2. For each, extract `Services Affected` list
3. Intersect with current plan's services
4. If overlap → tell user which plan and which services overlap → offer worktree
5. If user accepts → invoke worktree skill → record path in design doc
6. If user declines → proceed without worktree (user accepts collision risk)

This is cheap — just reading markdown files that are already on disk.

**Session resumption:** If the current plan's design doc already has a `## Worktree` / `## Worktrees` section (from a previous session that was `/clear`ed), reuse the existing worktree(s) instead of creating new ones. Verification steps:
1. Check worktree exists on disk: `git worktree list` should include the path
2. If missing: run `git worktree prune` first (clean stale entries), then recreate via worktree skill
3. Verify correct branch: `cd {worktree} && git branch --show-current` should match the branch recorded in the design doc
4. If wrong branch: warn user, don't silently proceed

**Limitation:** Overlap detection is service-level, not file-level. Two plans touching the same service but different files will still trigger the worktree offer. This is conservative — the cost of an unnecessary worktree is low, the cost of a missed collision is high.

### Worktree Directory

**Monorepo:** `.worktrees/{slug}/` in project root. One worktree per plan — all agents share it.

**Polyrepo:** `.worktrees/{slug}/` in each affected service repo. One worktree per plan per service repo. Agents working on a service cd into that service's worktree.

```
Monorepo:                          Polyrepo:
project/                           project/
  .worktrees/                        backend/          ← git repo
    plan-b/                            .worktrees/
      backend/                           plan-b/       ← worktree of backend
      frontend/                        src/
  backend/                           frontend/         ← git repo
  frontend/                            .worktrees/
                                         plan-b/       ← worktree of frontend
                                       src/
```

**Default dir:** `.worktrees/` (configurable via `worktree.dir` in `project.yml`).

All agents in the same plan share the same worktree(s). The wave-based sequencing already prevents agents within a plan from colliding.

### Worktree Lifecycle

**Monorepo lifecycle:**
```
Create (implement command, after parsing design doc)
  → Check if branch feature/{slug} already exists
    → If yes: git worktree add .worktrees/{slug} feature/{slug}  (reuse branch)
    → If no:  git worktree add .worktrees/{slug} -b feature/{slug}  (create branch)
  → If git worktree add fails: abort, report error, let caller decide
  → Verify gitignore covers worktree dir
  → Run setup commands per affected service (in worktree)
    → If setup fails: warn user, ask whether to continue without setup or abort
  → Record absolute worktree path in living state doc

Use (implementer agents)
  → Implement command passes absolute worktree path in agent prompt
  → Agents cd into worktree path as their working directory
  → All relative paths resolve against worktree root (same dir structure as main tree)
  → Git operations happen inside worktree — agents verify branch before committing
  → Commits go to the worktree's branch

Finish (finish command)
  → Detect worktree via living state doc's ## Worktree(s) section
  → Rebase onto updated main
    → If conflicts: abort rebase, report conflicted files, tell user how to resolve
  → Verify worktree is clean (git status --porcelain) before removal
  → Push branch, create PR
  → After merge: git worktree remove .worktrees/{slug}
    → If dirty: warn user, offer force removal or manual cleanup
```

**Polyrepo lifecycle:**
```
Create (implement command, after parsing design doc)
  → For EACH affected service repo:
    → cd into service directory
    → Check if branch feature/{slug} already exists in this repo
      → If yes: git worktree add .worktrees/{slug} feature/{slug}
      → If no:  git worktree add .worktrees/{slug} -b feature/{slug}
    → If fails: report which service failed, let caller decide per-service
    → Verify .worktrees/ is in that repo's .gitignore
    → Run setup command for that service (in its worktree)
  → Record all service worktree paths in living state doc

Use (implementer agents)
  → Implement command passes the service-specific worktree path per agent
  → Agent working on backend → cd {backend}/.worktrees/{slug}
  → Agent working on frontend → cd {frontend}/.worktrees/{slug}
  → Same rules as monorepo: verify branch, don't switch, commit in worktree

Finish (finish command)
  → Process each service worktree in merge order (migrations → producers → consumers)
  → Per service: rebase → push → PR → cleanup
  → If one service has rebase conflicts, others can still proceed
  → Clean up each worktree after its PR is created
```

### Setup Commands

Each service in `project.yml` can declare a `setup` command:

```yaml
services:
  - name: backend
    path: backend/
    setup: ./gradlew build
  - name: frontend
    path: frontend/
    setup: pnpm install
```

If no `setup` configured and `worktree.auto_detect_setup` is true (default), auto-detect from project files. Check in order, use first match per service directory:

1. `pnpm-lock.yaml` → `pnpm install`
2. `yarn.lock` → `yarn install`
3. `package-lock.json` → `npm install`
4. `package.json` (no lockfile) → `npm install`
5. `build.gradle.kts` / `build.gradle` → `./gradlew build`
6. `Cargo.toml` → `cargo build`
7. `go.mod` → `go mod download`
8. `poetry.lock` → `poetry install`
9. `uv.lock` → `uv sync`
10. `requirements.txt` → `pip install -r requirements.txt`
11. `pyproject.toml` (no lock) → `pip install -e .`

Setup runs once at worktree creation per affected service, not per agent spawn. Each setup command runs inside its service subdirectory within the worktree (e.g., `cd {worktree}/backend && ./gradlew build`).

**If setup fails (monorepo):** warn the user with the error output and ask: "Setup failed for {service}. Continue without setup, or abort worktree creation?" If abort, clean up via `git worktree remove --force`.

**If setup fails (polyrepo):** Run all service setups first, collect failures, then present a single batched summary (see Polyrepo Considerations → Partial failure). This avoids N sequential prompts for N service failures.

### Gitignore Safety

Before creating a worktree in a project-local directory:

1. `git check-ignore -q {worktree_dir}` — check if already ignored (this respects all gitignore sources: local, global, system)
2. If NOT ignored → check if `.worktrees` line already exists in `.gitignore` (handles race with concurrent sessions) → if not, add to `.gitignore` and commit
3. Proceed with worktree creation

**Polyrepo:** Run this check in each service repo that gets a worktree. Each repo has its own `.gitignore`.

This prevents worktree contents from being tracked.

### Living State Doc Changes

Add an optional `## Worktree` or `## Worktrees` section to the design doc template. This section is only present when the plan uses worktrees — absence means "no worktree, working in main tree." All commands treat a missing section as normal (no worktree), never as an error.

**Monorepo format** (single worktree):
```markdown
## Worktree
- **Path:** /absolute/path/to/project/.worktrees/my-feature
- **Branch:** feature/my-feature
```

**Polyrepo format** (per-service worktrees):
```markdown
## Worktrees
| Service | Path | Branch |
|---------|------|--------|
| backend | /absolute/path/to/backend/.worktrees/my-feature | feature/my-feature |
| frontend | /absolute/path/to/frontend/.worktrees/my-feature | feature/my-feature |
```

**Paths are absolute.** This avoids resolution ambiguity when commands run from different directories. The worktree skill writes absolute paths at creation time.

This lets any command (`/project:progress`, `/project:finish`, `/project:verify`) find the worktree(s) by reading the design doc. No filesystem scanning, no separate state files. Commands check for `## Worktree` (monorepo) first, then `## Worktrees` (polyrepo).

### Config Schema

```yaml
# .claude/project.yml additions
worktree:
  dir: .worktrees          # default — relative to repo root (monorepo: project root, polyrepo: each service root)
  auto_detect_setup: true  # try to detect setup commands (default true)

services:
  - name: backend
    path: backend/
    setup: ./gradlew build  # new optional field — runs inside worktree's service dir
  - name: frontend
    path: frontend/
    setup: pnpm install
```

### Polyrepo Considerations

In a polyrepo (`config.structure: polyrepo`), each service is its own git repo. Worktrees are created per-service-repo rather than once at the project root.

**Key differences from monorepo:**
- Worktree creation loops over affected service repos
- Each service gets its own `.worktrees/{slug}/` inside its repo directory
- The living state doc uses a table (service → path → branch) instead of a single path
- Gitignore check runs per-repo
- Finish processes services in merge order, each with its own rebase/PR cycle
- If one service has rebase conflicts, others can still proceed independently

**Partial failure:** If worktree creation or setup fails for some services, batch the failures and present a single summary:

```
Worktree creation results:
  ✅ backend — .worktrees/my-feature
  ✅ frontend — .worktrees/my-feature
  ❌ admin — setup failed: pnpm install exited with code 1

Options:
1. Continue with worktrees for backend + frontend, implement admin in main tree
2. Retry failed services
3. Abort all worktree creation
```

The living state doc only records successfully created worktrees. Services without a worktree entry are implemented in the main service directory. Downstream commands (verify, finish) handle this mixed state — they check the worktrees table for each service and fall back to the main directory if no entry exists.

### What Doesn't Change

- Brainstorm phase — unaffected, no worktrees needed during design
- Wave-based task scheduling — agents within a plan still sequence by waves
- Review flow — reviewers read from the worktree path, same as main tree
- Team management — unchanged, teams are per-plan not per-worktree
- Component-first isolation — still valid for intra-plan file collisions

---

## Implementation Tasks

| # | Task | Deps | Files |
|---|------|------|-------|
| 1 | Create worktree skill | — | `skills/worktree/SKILL.md` |
| 2 | Create worktree command | 1 | `commands/worktree.md` |
| 3 | Add overlap detection + task-service mapping to implement command | 1 | `commands/implement.md` |
| 4 | Update implementer skill for worktree paths | — | `skills/implementer/SKILL.md` |
| 5 | Update finishing-branch skill for worktree rebase + cleanup | — | `skills/finishing-branch/SKILL.md` |
| 6 | Update progress command to show worktree info | — | `commands/progress.md` |
| 7 | Update verify command for worktree awareness (mono + poly) | — | `commands/verify.md` |
| 8 | Add Service column to brainstorming task table template | — | `skills/brainstorming/SKILL.md` |
| 9 | Create review-design command + skill (independent) | — | `commands/review-design.md`, `skills/design-reviewer/SKILL.md` |

### Task Details

#### Task 1: Create worktree skill

New skill at `skills/worktree/SKILL.md`. Internal skill (not user-invocable) that handles:

- Detect project structure (monorepo vs polyrepo from `config.structure`)
- Directory selection (config > existing > default `.worktrees/`)
- **Monorepo path:** single worktree at project root
  1. Gitignore verification and fix
  2. Branch-aware creation:
     - Check if `feature/{slug}` branch exists: `git branch --list feature/{slug}`
     - If exists: `git worktree add .worktrees/{slug} feature/{slug}` (reuse)
     - If not: `git worktree add .worktrees/{slug} -b feature/{slug}` (create)
  3. Run setup commands per affected service inside worktree
  4. Return single absolute worktree path
- **Polyrepo path:** one worktree per affected service repo
  1. For each affected service (from design doc's `Services Affected`):
     - cd into service repo directory (`config.services[name].path`)
     - Gitignore verification and fix for that repo
     - Branch-aware creation (same logic as monorepo, but in service repo)
     - Run setup command for that service inside its worktree
  2. If one service fails: report which, let caller decide per-service (retry/skip/abort)
  3. Return map of service name → absolute worktree path
- **Error handling (both paths):**
  - If `git worktree add` fails (path exists, lock conflict, etc.):
    - Report the error to the caller
    - Suggest: "Worktree creation failed. You can: (1) fix manually and retry, or (2) proceed without a worktree"
    - Do NOT silently fall back — let the caller (implement command) decide

**Does NOT include:**
- Test baseline verification (too slow for multi-service, implement flow assumes working main)
- Global `~/.config` directory option (unnecessary complexity)

#### Task 2: Create worktree command

New command at `commands/worktree.md`. Thin wrapper for manual use:

```
/project:worktree [slug]
```

Use cases:
- Manual worktree setup before implementing
- Spike/experiment isolation outside the implement flow
- Invokes the worktree skill, reports path

#### Task 3: Add overlap detection to implement command

Insert step 5.5 in `commands/implement.md` (after step 5 "Parse the design doc", since we need the parsed service list):

```
5.5. **Check for overlapping active plans**
  - Check if current design doc already has a ## Worktree / ## Worktrees section
    → If yes: reuse existing worktree(s) (verify they exist via git worktree list)
    → If missing on disk: recreate via worktree skill
  - If no existing worktree: scan {plans_dir}/ for other *-design.md with status "implementing"
    → Extract services from each
    → If overlap with current plan's services:
      → Tell user which plan overlaps and on which services
      → Offer worktree isolation
      → If accepted: invoke worktree skill, record absolute path(s) in design doc
  - Pass worktree info to all implementer agent prompts
```

Also update the implementer spawn prompt to include worktree path when present:
```
Monorepo:
  Prompt:
    Your task: Task {N} — {title}
    Living state doc: {path to design doc}
    Working directory: {absolute worktree path or project root}
    Read the living state doc, then cd into the working directory and implement your task.

Polyrepo:
  Prompt:
    Your task: Task {N} — {title}
    Living state doc: {path to design doc}
    Service: {service name}
    Working directory: {absolute worktree path for this service, or service path}
    Read the living state doc, then cd into the working directory and implement your task.
```

**How does the lead know which service each task targets?** The living state doc's task table needs a `Service` column. Update the brainstorming skill's template from:

```markdown
| # | Task | Status | Assignee | Spec | Quality |
```

to:

```markdown
| # | Task | Service | Status | Assignee | Spec | Quality |
```

The `Service` column is populated during design (brainstorm already knows which services each task affects). For monorepo, this is informational. For polyrepo with worktrees, the implement lead uses it to map each task to the correct worktree path.

**Mapping logic:** For each task, look up `Service` column → find matching row in `## Worktrees` table → use that row's `Path` as the working directory. If a service has no worktree entry (skipped during creation), use the main service path.

#### Task 4: Update implementer skill for worktree paths

Add a section to `skills/implementer/SKILL.md`:

```markdown
## Worktree Mode

If your task prompt includes a **Working directory** that differs from the project root
or service root:

1. cd into the working directory — this is your root for all operations
2. The directory structure inside the worktree mirrors the original:
   - Monorepo worktree: same layout as project root (all services inside)
   - Polyrepo worktree: same layout as the service root (you're inside one service)
3. All relative paths resolve against the worktree root
4. Git operations (status, commit, push) happen inside the worktree
5. The branch is already set up — don't create or switch branches
6. Before committing, verify you're on the correct branch:
   `git branch --show-current` should match what's in the living state doc.
   If not, message the lead immediately.
7. To reference project config files like `.claude/project.yml`, read from the
   main project root (the worktree may not have gitignored files like `.claude/`)
```

#### Task 5: Update finishing-branch skill for worktree rebase + cleanup

Add a new `Step 0: Detect Worktree` to `skills/finishing-branch/SKILL.md` before Step 1, and **replace** the existing generic Step 8 (worktree cleanup) with the logic below.

**Flow change:** Step 0 runs a rebase *before* the existing Step 1 (verify tests). This is intentional — rebase first so tests run against the rebased code, not the pre-rebase state. If rebase has conflicts, there's nothing to test yet.

```markdown
## Step 0: Detect Worktree

Check the living state doc for a `## Worktree` (monorepo) or `## Worktrees` (polyrepo) section.

If neither section exists: skip to Step 1 (normal flow).

**Monorepo (single worktree):**
1. cd into worktree path (absolute path from design doc)
2. Before presenting options, rebase onto base branch:
   ```bash
   git fetch origin
   git rebase origin/{base-branch}
   ```
3. If rebase conflicts:
   - Run `git rebase --abort` to restore clean state
   - Report the conflicted files to the user
   - Tell user:
     "Rebase has conflicts in: {file list}
     Options:
     1. Resolve manually: cd {worktree-path}, run `git rebase origin/{base-branch}`,
        fix conflicts, `git rebase --continue`, then re-run `/project:finish`
     2. Skip rebase and create PR as-is (GitHub will show conflicts)
     3. Keep the branch and handle it later"
   - Wait for user choice. Do NOT auto-resolve.
4. After successful finish (Option 1 or 2):
   - Verify worktree is clean: `cd {worktree-path} && git status --porcelain`
   - If clean: `cd {project-root} && git worktree remove {worktree-path}`
   - If dirty: warn user — "Worktree has uncommitted changes. Force remove, or clean up manually?"
     - Force: `git worktree remove --force {worktree-path}`
     - Manual: keep worktree, user handles it
5. Remove `## Worktree` section from living state doc
6. Run `git worktree prune` to clean up any stale entries

**Polyrepo (per-service worktrees):**
Process each service worktree from the `## Worktrees` table, in merge order
(migrations → producers → consumers — same order as existing Step 6):
1. For each service row in the table:
   - cd into the service worktree path
   - Rebase onto base branch: `git fetch origin && git rebase origin/{base-branch}`
   - If rebase conflicts: same conflict handling as monorepo, but per-service.
     Other services can continue independently.
   - Present finish options per service (merge/PR/keep/discard)
   - After finish: verify clean, remove worktree, prune
2. For services NOT in the `## Worktrees` table (skipped during creation):
   - Process in the main service directory as normal (existing Step 1+ flow)
3. After all services processed:
   - Remove `## Worktrees` section from living state doc
   - Update living state doc with per-service results:
     "backend: PR #42 created, frontend: PR #43 created, admin: merged locally"
```

**What changes in the existing skill:** Step 0 is new (added before Step 1). The existing Step 8 (generic worktree cleanup) is removed — its functionality is now part of Step 0's cleanup logic (steps 4-6 in monorepo, step 1.d in polyrepo).

#### Task 6: Update progress command to show worktree info

Add worktree info to the progress report. Parse `## Worktree` (monorepo) or `## Worktrees` (polyrepo) from the design doc:

```
Monorepo:
  Feature: {name}
  Status: {overall status}
  Plan: {file path}
  Worktree: {absolute path} (branch: feature/{slug})
  Tasks: ...

Polyrepo:
  Feature: {name}
  Status: {overall status}
  Plan: {file path}
  Worktrees:
    backend: {absolute path} (branch: feature/{slug})
    frontend: {absolute path} (branch: feature/{slug})
  Tasks: ...
```

Paths come directly from the living state doc (always absolute). Parse `## Worktree` for monorepo (bullet list with Path/Branch) or `## Worktrees` for polyrepo (markdown table with Service/Path/Branch columns).

Only show worktree info if the section exists in the design doc.

#### Task 7: Update verify command for worktree awareness

Update `commands/verify.md` to detect and use worktrees:

```markdown
## Worktree Detection

Before running verification:
1. Find the active design doc
2. Check for `## Worktree` (monorepo) or `## Worktrees` (polyrepo) section

Monorepo (## Worktree):
3. cd into the single worktree path for all verification steps
   (test execution, git state checks, file existence checks)

Polyrepo (## Worktrees):
3. For each service in the worktrees table:
   - cd into that service's worktree path
   - Run that service's test command
   - Check git state (correct branch, clean status)
4. For services NOT in the worktrees table (skipped during creation):
   - Verify in the main service directory as normal

No worktree section:
3. Verify in the main working tree as normal
```

The verify command runs tests and checks git state across affected services. Without this change, it would verify the main tree (which may not have the implementation) instead of the worktree.

#### Task 8: Add Service column to brainstorming task table template

Update `skills/brainstorming/SKILL.md` strict template. Change the implementation tasks table from:

```markdown
| # | Task | Status | Assignee | Spec | Quality |
|---|------|--------|----------|------|---------|
| 1 | ... | pending | — | — | — |
```

to:

```markdown
| # | Task | Service | Status | Assignee | Spec | Quality |
|---|------|---------|--------|----------|------|---------|
| 1 | ... | backend | pending | — | — | — |
```

The `Service` column is populated during design. For single-service tasks it's straightforward. For cross-service tasks (e.g., "update API contract between backend and frontend"), use the primary service where most code changes happen — the task description should note secondary services.

This enables the implement command to map tasks to the correct worktree path in polyrepo mode. In monorepo mode the column is informational but still useful for understanding task scope.

#### Task 9: Create review-design command + skill

> **Scope note:** This task is a separate feature (design doc review) that surfaced during this design's own review process. It's bundled here because it's small, self-contained, has no dependencies on Tasks 1-7, and naturally complements the worktree workflow (review design → implement in worktree). It can be implemented independently or deferred without affecting worktree functionality.

New command at `commands/review-design.md` and internal skill at `skills/design-reviewer/SKILL.md`.

**The gap:** `/project:review` reviews implemented code against task specs. There's no way to review a design doc before implementation starts. Currently this requires improvised agent prompts — not repeatable or discoverable.

**Command: `/project:review-design [plan file path]`**

Finds the latest design doc (or uses the provided path) and runs two-stage parallel review:

```
Stage 1 — Spec completeness:
  - Are all scenarios and edge cases addressed?
  - Are there integration gaps with existing commands/skills?
  - Are there ambiguities that would block implementation?
  - Is anything over/under-engineered?

Stage 2 — Feasibility:
  - Will the proposed commands/tools actually work as described?
  - Are there race conditions, failure modes, or conflicts?
  - Is the user workflow intuitive?
  - Are there practical concerns the design missed?
```

**Review strategy:** Uses `config.review.strategy` (same as code review):
- `parallel` (default): spawn 2 reviewers per stage with `config.review.parallel_models`, merge findings using agreed/model-A-only/model-B-only categories
- `single`: spawn 1 reviewer per stage with `config.review.single_model`

**Skill: `skills/design-reviewer/SKILL.md`**

Internal skill (not user-invocable) that guides each reviewer agent. Inputs:
1. The design doc
2. All files the design proposes to create or modify (reads them for integration context)
3. Which stage (completeness vs feasibility)

Output format per reviewer:
```
## Design Review — {Feature Name}

**Verdict: ✅ Ready** or **❌ Issues Found**

### {Stage-specific sections}
- Critical: {must fix before implementing}
- Important: {should fix}
- Minor: {nice to fix}
```

**Merge logic** (lead does this, not a separate agent — same pattern as code review):

| Category | Meaning | Action |
|----------|---------|--------|
| Agreed | Both models flagged | High confidence — must address |
| Model-B-only | Only the stronger model found it | Likely real — review and usually apply |
| Model-A-only | Only the faster model found it | Review, may be stylistic |
| Contradictions | Models disagree | Present both, user decides |

**After review:** Update design doc status to `reviewed` if passing, or present findings and suggest fixes. This slots naturally into the flow:

```
/project:brainstorm → /project:review-design → /clear → /project:implement
```

---

## Decisions & Context

1. **One worktree per plan, not per agent.** Agents within a plan already sequence via waves. Worktrees solve inter-plan conflicts, not intra-plan ones.

2. **No test baseline verification.** The superpowers skill runs full tests after worktree creation. For multi-service repos this is too slow and the implement flow already assumes main is green.

3. **Rebase, not merge.** When the second plan finishes, it rebases onto main (which now has plan A's changes). This keeps history linear and makes conflicts explicit. If rebase conflicts, the user resolves — no auto-resolution. The finish skill aborts the rebase and presents clear options.

4. **Worktree path in the living state doc.** Every downstream command can find the worktree by reading the design doc. No filesystem scanning, no separate state files. Paths are absolute to avoid resolution ambiguity.

5. **Setup commands are optional.** Auto-detection covers common cases with explicit priority order (lockfile-first). Explicit `setup` in project.yml is for non-standard projects or when auto-detect gets it wrong.

6. **Project-local worktrees only.** No global `~/.config` option. Worktrees belong to the project. Keeps things simple.

7. **Both monorepo and polyrepo.** Monorepo gets one worktree at project root. Polyrepo gets one worktree per affected service repo, tracked in a table in the living state doc. The finish flow processes polyrepo worktrees in merge order (same ordering it already uses for multi-service PRs).

8. **Absent `## Worktree` = no worktree.** The section is optional in the living state doc template. Old design docs without it work unchanged. Commands never error on its absence.

9. **Session resumption via design doc.** If a user runs `/clear` between worktree creation and implementation, the design doc's `## Worktree` section persists on disk. The implement command detects this and reuses the existing worktree instead of creating a new one.

10. **Explicit failure, no silent fallback.** If `git worktree add` fails, the skill reports the error and lets the caller decide (retry, proceed without, or abort). No automatic degradation that could mask problems.

11. **Service-level overlap detection (conservative).** Detection checks service overlap, not file-level overlap. Two plans touching the same service but different files still trigger the worktree offer. The cost of an unnecessary worktree is low; the cost of a missed collision is high.

12. **Living state doc race condition accepted.** Two sessions can theoretically write to the same design doc simultaneously. In practice, each session writes to its *own* design doc (plan A doc vs plan B doc). The only shared write is if both edit the same doc, which shouldn't happen — each plan has its own living state doc.

13. **Task table gets a Service column.** Required for polyrepo worktree routing — the implement lead needs to map each task to the correct service worktree path. Populated during design phase. In monorepo mode it's informational but still useful.

14. **Rebase before test verification.** Step 0 (worktree rebase) runs before the existing Step 1 (verify tests). This is intentional — tests should run against rebased code, and if rebase has conflicts there's nothing to test yet.

15. **Polyrepo setup failures are batched.** All service setups run first, failures are collected, then presented as a single summary with one decision point. This avoids N sequential prompts for N services.

16. **Mixed worktree state in polyrepo.** If some services have worktrees and others don't (due to partial failure), downstream commands handle both. They check the worktrees table for each service — if no entry, use the main service directory. This means finish/verify can process a mix of worktree and non-worktree services in the same plan.
