---
name: project:finish
description: Finish a branch — PR creation, multi-service ordering, changelog
argument-hint: "[service name]"
allowed-tools: [Read, Glob, Grep, Bash, Edit, Write, AskUserQuestion]
---

<objective>
Branch finishing via the finishing-branch skill. Handles git repos, auto-deploy awareness, multi-service PR ordering, and changelog.
</objective>

<context>
- `$ARGUMENTS` — service name (optional, will detect from git/MCP status if omitted)
</context>

<process>
1. **Load project config** from `.claude/project.yml` (defaults if missing)

## Primary: MCP-powered discovery

2. **Identify affected services** (if no service name provided):
   - Call `list_branches(pattern: "feature/*")` → aggregate branches across all repos
   - Call `verify_workspace()` → find repos with dirty trees or unpushed commits
   - If MCP calls fail → jump to **Fallback** below

3. **Get detailed status** for each candidate service:
   - Call `repo_status(service: <name>)` → branch, dirty files, unpushed commits
   - Present findings and ask user which service(s) to finish

4. Invoke the `project-orchestrator:finishing-branch` skill to handle branch finishing
5. If a service name was provided via `$ARGUMENTS`, start with that service

## Fallback: Manual discovery (if MCP unavailable)

1. Check git status across service directories to identify which ones have uncommitted/unpushed changes
2. Ask the user which to finish
3. Invoke the `project-orchestrator:finishing-branch` skill

## After finishing

Suggest:
- `/project:changelog` to add changelog entries
- `/project:verify` to run verification

</process>

<success_criteria>
- [ ] MCP tools used first for service discovery (graceful fallback to manual)
- [ ] Branch finished (merged locally, PR created, or kept as-is per user choice)
- [ ] User told about `/project:changelog` and `/project:verify`
</success_criteria>
