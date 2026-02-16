---
name: project:worktree
description: Create an isolated git worktree for a plan — manual setup for parallel implementation or spike isolation
---

<objective>
Create a git worktree for a plan slug, enabling isolated parallel work. Thin wrapper around the worktree skill for manual use outside the `/project:implement` flow.

Use cases:
- Manual worktree setup before running `/project:implement`
- Spike or experiment isolation outside the normal implement flow
- Re-creating a worktree that was cleaned up prematurely
</objective>

<context>
- Project config: @.project-orchestrator/project.yml
</context>

<process>
1. Parse project config (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)
2. Determine the plan slug:
   - If user provided `[slug]` argument: use it
   - If not: scan `{config.plans_dir}/` for design docs with status `designing` or `approved`
     - If exactly one found: extract slug from filename (`YYYY-MM-DD-{slug}-design.md`)
     - If multiple found: ask user to pick or provide a slug
     - If none found: ask user for a slug (this may be a spike with no design doc)
3. Find the design doc at `{config.plans_dir}/*-{slug}-design.md` (if it exists)
   - If found: extract `Services Affected` list from the design doc
   - If not found: ask user which services are affected (or default to project root for monorepo)
4. Invoke the `project-orchestrator:worktree` skill with:
   - **slug** — the plan slug
   - **services** — the affected services list
   - **design_doc_path** — absolute path to the design doc (if it exists)
5. Report the result to the user:

   **Monorepo:**
   ```
   Worktree created:
     Path: {absolute_worktree_path}
     Branch: feature/{slug}

   To implement in this worktree:
     cd {absolute_worktree_path}
   Or run /project:implement — it will detect the worktree automatically.
   ```

   **Polyrepo:**
   ```
   Worktrees created:
     backend: {absolute_path} (branch: feature/{slug})
     frontend: {absolute_path} (branch: feature/{slug})

   Run /project:implement — it will route agents to the correct worktree per service.
   ```

6. If the worktree skill reports errors, relay them to the user with the suggested options
</process>

<success_criteria>
- [ ] Worktree(s) created successfully (or clear error with options reported)
- [ ] Design doc updated with `## Worktree` / `## Worktrees` section (if design doc exists)
- [ ] User told the worktree path(s) and next steps
</success_criteria>
