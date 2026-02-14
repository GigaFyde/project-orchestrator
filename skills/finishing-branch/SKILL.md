---
name: project-orchestrator:finishing-branch
description: Use when implementation is complete and ready to merge/PR — handles git repos, auto-deploy awareness, multi-service PR ordering, and changelog.
---

# Finishing a Development Branch

## Overview

Guide completion of development work.

**Core principle:** Verify tests → Changelog → Present options → Execute choice → Move plan → Clean up.

**Announce at start:** "I'm using the finishing-branch skill to complete this work."

## Config Loading

1. Check if `.claude/project.yml` exists
2. If yes: parse and extract `services`, `structure` (polyrepo/monorepo), `plans_dir`, `plans_structure`
3. If no: use defaults (monorepo, single service at root, `docs/plans/` flat)

---

## Step 1: Identify Affected Services

**Polyrepo** (`config.structure: polyrepo`): Each service folder is its own git repo. "Finish branch" means **per-service**.

**Monorepo** (`config.structure: monorepo`): Single repo, single branch operation.

### Primary: MCP-powered discovery

1. Call `list_branches(pattern: "feature/*")` → aggregate feature branches across all repos
2. Call `verify_workspace()` → find repos with dirty trees or unpushed commits
3. For each candidate, call `repo_status(service: <name>)` → detailed branch/dirty/unpushed status
4. Present findings to user

If MCP tools are unavailable, fall back to manual git checks per service directory.

**Repeat Steps 2-5 for each affected service.**

---

## Step 2: Verify Tests

**Before presenting options, verify tests pass in EACH affected service.**

Test commands come from `config.services[name].test`, the project's root CLAUDE.md, or auto-detection.

**If tests fail:** Stop. Fix before proceeding. Cannot merge/PR with failing tests.

**If tests pass:** Continue to Step 3.

---

## Step 3: Changelog

If `config.services[name].changelog` is configured, invoke the `project-orchestrator:changelog` skill for each affected service before finishing.

If no changelog configured, skip this step.

---

## Step 4: Present Options

Present exactly these 4 options per service:

```
[service-name] implementation complete. What would you like to do?

1. Merge back to <base-branch> locally
2. Push and create a Pull Request
3. Keep the branch as-is (I'll handle it later)
4. Discard this work

Which option?
```

Use `config.services[name].branch` for the base branch (default: `main`).

---

## Step 5: Execute Choice

### Option 1: Merge Locally

```bash
cd <service>
git checkout <base-branch>   # from config.services[name].branch
git pull
git merge <feature-branch>

# Verify tests on merged result
<test command>

# If tests pass
git branch -d <feature-branch>
```

**Auto-deploy warning:** If `config.services[name].auto_deploy` is `true`:

```
Warning: Pushing <service> to <base-branch> will trigger auto-deploy.
Push now, or keep local?
```

### Option 2: Push and Create PR

```bash
cd <service>
git push -u origin <feature-branch>

gh pr create --title "<title>" --body "$(cat <<'EOF'
## Summary
<2-3 bullets>

## Test Plan
- [ ] <verification steps>
EOF
)"
```

**Never force push** — teammates may be working on the same repos.

### Option 3: Keep As-Is

Report: "Keeping branch `<name>` in `<service>/`. No changes made."

### Option 4: Discard

**Confirm first:**
```
This will permanently delete branch <name> in <service>/.
All commits: <commit-list>

Type 'discard' to confirm.
```

Wait for exact confirmation. Then:
```bash
cd <service>
git checkout <base-branch>
git branch -D <feature-branch>
```

---

## Step 6: Multi-Service PR Ordering

When changes span multiple services, suggest merge order:

```
1. Database migrations first
2. Producers next (API endpoints, event publishers)
3. Consumers last (frontend, admin, downstream services)
```

This prevents consumers from deploying against an API that doesn't exist yet.

---

## Step 7: Living State Doc

If working from a plan in `{config.plans_dir}/`:

1. **Update status** in the design doc: `## Status: complete`
2. **Move doc** (if `config.plans_structure` is `standard`):
   ```bash
   mv {plans_dir}/<filename>.md {plans_dir}/completed/
   ```
3. **Update `{plans_dir}/INDEX.md`** (if standard structure):
   - Remove the entry from `## Active`
   - Add it to `## Completed` (use `completed/` path prefix, keep description)

**If flat structure:** Just update the status in the doc, no moving needed.

---

## Step 8: Worktree Cleanup

If using git worktrees (Options 1, 2, 4):

```bash
git worktree list | grep <feature-branch>
git worktree remove <worktree-path>
```

For Option 3: Keep worktree.

---

## Quick Reference

| Option | Merge | Push | Cleanup Branch | Auto-deploy Risk |
|--------|-------|------|----------------|------------------|
| 1. Merge locally | Yes | User decides | Yes | If pushed + auto_deploy=true |
| 2. Create PR | No | Yes | No | On PR merge only |
| 3. Keep as-is | No | No | No | None |
| 4. Discard | No | No | Yes (force) | None |

---

## Red Flags

**Never:**
- Proceed with failing tests
- Force-push (teammates on same repos)
- Merge without verifying tests on result
- Delete work without typed confirmation
- Push auto-deploy service without warning user
- Skip changelog (when configured)

**Always:**
- Verify tests before offering options
- Present exactly 4 options
- Warn about auto-deploy before pushing (check `config.services[name].auto_deploy`)
- Get typed confirmation for Option 4
- Invoke `project-orchestrator:changelog` before finishing (when changelog configured)
- Move plan to `completed/` and update INDEX.md (when standard structure)
- Handle each service separately in polyrepo structure

---

## Related Commands & Skills

| When | Action |
|------|--------|
| Need to verify work first | Suggest user run `/project:verify` |
| Writing changelog entries | Suggest user run `/project:changelog` |
