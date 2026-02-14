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

2. **Identify affected services** (if no service name provided):
   - Call `list_branches(pattern: "feature/*")` → aggregate branches across all repos (if MCP available)
   - Check git status across service directories: `cd <service> && git status && git branch --show-current`
   - Present findings and ask user which service(s) to finish

3. Invoke the `project-orchestrator:finishing-branch` skill to handle branch finishing
4. If a service name was provided via `$ARGUMENTS`, start with that service

## After finishing

Suggest:
- `/project:changelog` to add changelog entries
- `/project:verify` to run verification

</process>

<success_criteria>
- [ ] Affected services identified (via git status checks)
- [ ] Branch finished (merged locally, PR created, or kept as-is per user choice)
- [ ] User told about `/project:changelog` and `/project:verify`
</success_criteria>
