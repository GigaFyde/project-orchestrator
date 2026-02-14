---
name: project:verify
description: Verify completed work — evidence-based checks across all affected services
---

<objective>
Evidence-based verification via the verification skill. Ensures tests pass, contracts match, git state is correct, and deployment is confirmed before claiming completion.
</objective>

<process>
1. Load project config from `.claude/project.yml` (defaults if missing)
2. Invoke the `project-orchestrator:verification` skill to run evidence-based verification
   - Skill uses `verify_workspace()` MCP tool for git state checks (falls back to manual git commands if MCP unavailable)
   - Test commands from `config.services[name].test` or auto-detected
3. After verification passes, suggest `/project:finish` if the branch is ready to merge
</process>

<success_criteria>
- [ ] All affected service tests pass with fresh evidence
- [ ] Cross-service contracts verified (if applicable)
- [ ] Git state correct (right branch, clean status)
- [ ] User told next step (`/project:finish`)
</success_criteria>
