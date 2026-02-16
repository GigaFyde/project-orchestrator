---
name: project:changelog
description: Add standardized changelog entries to a service
argument-hint: "[service name]"
---

<objective>
Changelog entry creation. Ensures standardized format, correct location, and meaningful content.
</objective>

<context>
- `$ARGUMENTS` — service name (optional, will detect from recent git activity if omitted)
- Project config: @.project-orchestrator/project.yml
- Changelog skill: @skills/changelog/SKILL.md
</context>

<process>
1. Parse project config (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)
2. Follow the changelog skill (loaded above) to create changelog entries
3. If a service name was provided, add the changelog entry for that service using `config.services[name].changelog`
4. Otherwise, check recent git activity to identify which services were changed and ask the user which to update
</process>

<success_criteria>
- [ ] Changelog entry added to correct changelog file in correct format
</success_criteria>
