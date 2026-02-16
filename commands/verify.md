---
name: project:verify
description: Verify completed work — evidence-based checks across all affected services
---

<objective>
Evidence-based verification. Ensures tests pass, contracts match, git state is correct, and deployment is confirmed before claiming completion.
</objective>

<context>
- Project config: @.project-orchestrator/project.yml
- Verification skill: @skills/verification/SKILL.md
</context>

<process>
1. Parse project config (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)
2. Find the active design doc in `{config.plans_dir}/`
3. **Worktree detection** — check the design doc for worktree sections:

   **Monorepo (`## Worktree`):**
   - cd into the single worktree path for all verification steps
     (test execution, git state checks, file existence checks)

   **Polyrepo (`## Worktrees`):**
   - For each service in the worktrees table:
     - cd into that service's worktree path
     - Run that service's test command
     - Check git state (correct branch, clean status)
   - For services NOT in the worktrees table (skipped during creation):
     - Verify in the main service directory as normal

   **No worktree section:**
   - Verify in the main working tree as normal

4. Follow the verification skill (loaded above) to run evidence-based verification
   - Pass the resolved working directory (worktree path or main tree) for each service
   - Skill uses manual git commands for git state checks (`git status`, `git branch --show-current` per service)
   - Test commands from `config.services[name].test` or auto-detected
5. After verification passes, suggest `/project:finish` if the branch is ready to merge
</process>

<success_criteria>
- [ ] All affected service tests pass with fresh evidence
- [ ] Cross-service contracts verified (if applicable)
- [ ] Git state correct (right branch, clean status)
- [ ] User told next step (`/project:finish`)
</success_criteria>
