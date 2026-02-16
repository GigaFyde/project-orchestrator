---
name: project:progress
description: Check feature implementation progress and suggest next steps
allowed-tools: [Read, Glob, Grep, AskUserQuestion]
---

<objective>
Status checker and router. Query feature status from design docs, report progress, and suggest the appropriate next command. Uses MCP tools when available, falls back to file parsing.
</objective>

<context>
- Project config: @.project-orchestrator/project.yml
- Plans index: @docs/plans/INDEX.md
</context>

<process>

## Primary: MCP-powered approach

1. **Parse project config** (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)

2. **Find active features** — call `list_features(status: "active")`
   - If MCP call fails or returns error → jump to **Fallback** below
   - If no active features: "No active feature plan found. Run `/project:brainstorm` to start a new feature."

3. **Select feature:**
   - If user specified a slug in command args → use that slug
   - If single active feature → auto-select it
   - If multiple active features → use AskUserQuestion to let user pick

4. **Get detailed progress** — call `feature_progress(slug: <selected>)`

5. **Get recent activity** — call `get_activity_log(feature: <slug>, limit: 5)`

6. **Check for worktree info** — parse the design doc for `## Worktree` (monorepo) or `## Worktrees` (polyrepo) section. Only include in report if the section exists.

7. **Report:**
   ```
   Feature: {name}
   Status: {overall status}
   Plan: {file path}
   Worktree: {absolute path} (branch: {branch})              # monorepo — only if ## Worktree exists
   Worktrees:                                                  # polyrepo — only if ## Worktrees exists
     {service}: {absolute path} (branch: {branch})
     {service}: {absolute path} (branch: {branch})

   Tasks: {pending} pending | {in-progress} in-progress | {complete} complete | {reviewed} reviewed

   Recent Activity:
   - {timestamp}: {action} — {details}
   - ...
   ```

8. **Check for review analytics** — read `.project-orchestrator/review-analytics.json` at the consumer project root
   - If the file does not exist → skip this section silently (no error, no message)
   - If it exists, parse the `summary` object and append to the report:
     ```
     Review Analytics:
       Total reviews: {summary.total_reviews} | Auto-approved: {summary.auto_approved} | Auto-rejected: {summary.auto_rejected} | Human-decided: {summary.human_decided}
       Avg fix iterations: {summary.avg_fix_iterations}

       Model Accuracy:
         {model}: TP {true_positive} | FP {false_positive} | Missed {missed}
         {model}: TP {true_positive} | FP {false_positive} | Missed {missed}

       Service Issues:
         {service} ({reviews} reviews): {common_issues joined by ", "}
         {service} ({reviews} reviews): {common_issues joined by ", "}
     ```
   - Only show "Model Accuracy" subsection if `summary.model_accuracy` exists and has entries
   - Only show "Service Issues" subsection if `summary.by_service` exists and has entries

9. **Suggest next action** (same logic as below)

## Fallback: Manual approach (if MCP unavailable)

1. **Find the design doc** — check `{config.plans_dir}/INDEX.md` for active plans, or look for `{config.plans_dir}/*-design.md`
   - If none exists: "No active feature plan found. Run `/project:brainstorm` to start a new feature."

2. **Parse status** — extract overall status and task breakdown:
   - Pending / In-progress / Complete (unreviewed) / Reviewed / Failed review counts

3. **Check for worktree info** — parse the design doc for `## Worktree` (monorepo) or `## Worktrees` (polyrepo) section. Only include in report if the section exists.
   - Monorepo (`## Worktree`): extract Path and Branch from bullet list
   - Polyrepo (`## Worktrees`): extract Service, Path, and Branch columns from markdown table

4. **Report:**
   ```
   Feature: {name}
   Status: {overall status}
   Plan: {file path}
   Worktree: {absolute path} (branch: {branch})              # monorepo — only if ## Worktree exists
   Worktrees:                                                  # polyrepo — only if ## Worktrees exists
     {service}: {absolute path} (branch: {branch})
     {service}: {absolute path} (branch: {branch})

   Tasks: {pending} pending | {in-progress} in-progress | {complete} complete | {reviewed} reviewed
   ```

5. **Check for review analytics** — read `.project-orchestrator/review-analytics.json` at the consumer project root
   - If the file does not exist → skip this section silently (no error, no message)
   - If it exists, parse the `summary` object and append to the report:
     ```
     Review Analytics:
       Total reviews: {summary.total_reviews} | Auto-approved: {summary.auto_approved} | Auto-rejected: {summary.auto_rejected} | Human-decided: {summary.human_decided}
       Avg fix iterations: {summary.avg_fix_iterations}

       Model Accuracy:
         {model}: TP {true_positive} | FP {false_positive} | Missed {missed}
         {model}: TP {true_positive} | FP {false_positive} | Missed {missed}

       Service Issues:
         {service} ({reviews} reviews): {common_issues joined by ", "}
         {service} ({reviews} reviews): {common_issues joined by ", "}
     ```
   - Only show "Model Accuracy" subsection if `summary.model_accuracy` exists and has entries
   - Only show "Service Issues" subsection if `summary.by_service` exists and has entries

6. **Suggest next action**

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
- [ ] Review analytics summary shown if `.project-orchestrator/review-analytics.json` exists (silently skipped if missing)
- [ ] Next action suggested based on current state
</success_criteria>
