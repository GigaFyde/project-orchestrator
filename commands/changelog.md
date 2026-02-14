---
name: project:changelog
description: Add standardized changelog entries to a service
argument-hint: "[service name]"
---

<objective>
Changelog entry creation via the changelog skill. Ensures standardized format, correct location, and meaningful content.
</objective>

<context>
- `$ARGUMENTS` — service name (optional, will detect from recent git activity if omitted)
</context>

<process>
1. Load project config from `.claude/project.yml` (defaults if missing)
2. Invoke the `project-orchestrator:changelog` skill to create changelog entries
3. If a service name was provided, add the changelog entry for that service using `config.services[name].changelog`
4. Otherwise, check recent git activity to identify which services were changed and ask the user which to update
</process>

<success_criteria>
- [ ] Changelog entry added to correct changelog file in correct format
</success_criteria>
