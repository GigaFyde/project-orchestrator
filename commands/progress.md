---
name: project:progress
description: Check feature implementation progress and suggest next steps
allowed-tools: [Read, Glob, Grep, AskUserQuestion]
---

<objective>
Status checker and router. Query feature status from design docs, report progress, and suggest the appropriate next command. Uses MCP tools when available, falls back to file parsing.
</objective>

<process>

## Primary: MCP-powered approach

1. **Load project config** from `.claude/project.yml` (defaults if missing)

2. **Find active features** — call `list_features(status: "active")`
   - If MCP call fails or returns error → jump to **Fallback** below
   - If no active features: "No active feature plan found. Run `/project:brainstorm` to start a new feature."

3. **Select feature:**
   - If user specified a slug in command args → use that slug
   - If single active feature → auto-select it
   - If multiple active features → use AskUserQuestion to let user pick

4. **Get detailed progress** — call `feature_progress(slug: <selected>)`

5. **Get recent activity** — call `get_activity_log(feature: <slug>, limit: 5)`

6. **Report:**
   ```
   Feature: {name}
   Status: {overall status}
   Plan: {file path}

   Tasks: {pending} pending | {in-progress} in-progress | {complete} complete | {reviewed} reviewed

   Recent Activity:
   - {timestamp}: {action} — {details}
   - ...
   ```

7. **Suggest next action** (same logic as below)

## Fallback: Manual approach (if MCP unavailable)

1. **Find the design doc** — check `{config.plans_dir}/INDEX.md` for active plans, or look for `{config.plans_dir}/*-design.md`
   - If none exists: "No active feature plan found. Run `/project:brainstorm` to start a new feature."

2. **Parse status** — extract overall status and task breakdown:
   - Pending / In-progress / Complete (unreviewed) / Reviewed / Failed review counts

3. **Report:**
   ```
   Feature: {name}
   Status: {overall status}
   Plan: {file path}

   Tasks: {pending} pending | {in-progress} in-progress | {complete} complete | {reviewed} reviewed
   ```

4. **Suggest next action**

## Next Action Logic

| State | Suggestion |
|-------|-----------|
| Status is `brainstorming` or `designing` | "Design in progress. Continue with `/project:brainstorm`." |
| Tasks pending, none in-progress | "Ready to implement. Run `/project:implement`." |
| Tasks in-progress | "Implementation in progress. Workers are active." |
| Tasks complete but unreviewed | "Tasks ready for review. Run `/project:review`." |
| All tasks reviewed with pass | "All reviewed. Run `/project:verify` then `/project:finish`." |
| Some tasks have failed reviews | "Review issues found. Fix the issues, then run `/project:review` again." |
| Status is `complete` | "Feature complete. Run `/project:finish` if not already merged." |

</process>

<success_criteria>
- [ ] MCP tools called first (graceful fallback to manual parsing)
- [ ] Status reported with task counts
- [ ] Recent activity shown (MCP path only)
- [ ] Next action suggested based on current state
</success_criteria>
