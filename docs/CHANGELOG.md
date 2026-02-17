# Changelog

### 2026-02-17 - Skill & command cleanup

**Summary:** Removed dead Dev-MCP code from 5 files, fixed worktree `cd` shell-wedging danger, and hardened review report templates.

**Changes:**
- Replace hardcoded `Sonnet-only`/`Haiku-only` labels in review report with `{Model-B}-only`/`{Model-A}-only` — report now reflects configured model names
- Add `bun.lockb`/`bun install` at priority 2 in worktree setup auto-detection
- Replace all `cd {worktree-path}` with `git -C {worktree-path}` in finishing-branch skill — prevents shell session wedging when worktrees are deleted
- Remove Dev-MCP dead code (`save_state`, `load_state`, `agent_handoff`, `report_activity`, `acquire_lock`, `release_lock`) from brainstorming skill, implementer skill, implement command, and progress command
- Remove MCP-first approach from progress command — file-based approach is now the only path
- Clean up stale MCP references in progress objective and implementer agent file (review finding)

### 2026-02-16 - Fix reviewer agent skill loading

**Summary:** Reviewer agents no longer use hardcoded paths to find their skill files, fixing failures when the plugin is installed via cache.

**What prompted the change:**
- Design-reviewer, spec-reviewer, and quality-reviewer agents referenced `~/project-orchestrator/skills/...` to load their SKILL.md files
- This path only works if the plugin repo is cloned at that exact location — breaks when installed as a cached plugin
- Agents would fall back to running `find` commands, triggering permission prompts

**Problem solved:**
- Added `skills:` frontmatter to all three reviewer agents, matching the pattern already used by the implementer agent
- Removed hardcoded path instructions from agent First Steps
- Updated brainstorming skill's agent table to reflect auto-loaded skills
- No more `~/project-orchestrator` references anywhere in the codebase
