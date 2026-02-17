---
name: project:test
description: Run browser test scenarios from a design doc
argument-hint: "[plan file path] [--no-auto-resume]"
allowed-tools: [Read, Write, Edit, Glob, Grep, Bash, Task, AskUserQuestion]
skills: [project-orchestrator:test-lead]
---

<objective>
Browser test orchestrator. Read a design doc's Test Plan section, spawn test-executor agents sequentially to execute scenarios via Chrome DevTools MCP, collect results, and update the living state doc.
</objective>

<context>
- `$ARGUMENTS` — plan file path + optional `--no-auto-resume` flag
- Project config: @.project-orchestrator/project.yml
- Plans index: @docs/plans/INDEX.md
</context>

<process>
1. **Parse project config** (auto-loaded via @.project-orchestrator/project.yml, use defaults if missing)
   - Extract `test.model` (default: sonnet) for spawning test-executor agents
   - Extract `test.screenshot_on_failure` (default: true)
   - Extract `test.base_url` (default: null — must confirm at runtime)

2. **Find the design doc**
   - If a plan file path was provided in arguments, use it
   - Otherwise, check `{config.plans_dir}/INDEX.md` for active plans, or find `{config.plans_dir}/*-design.md`
   - If no design doc found: "No design doc found. Nothing to test."
   - If design doc has no `## Test Plan` section: "No test plan found in design doc. Add a Test Plan section first."

3. **Pre-flight validation**
   - Verify Chrome DevTools MCP is available (`list_pages`). If unavailable, abort.
   - Confirm base URL with user (from config or test plan)
   - Present setup steps / prerequisites from test plan and confirm with user

4. **Write state file** — `.project-orchestrator/state.json` with `"phase": "testing"`

5. **Create team** — `TeamCreate("test-{slug}")`

6. **Create screenshot directory** — `.project-orchestrator/screenshots/{slug}/`

7. **Execute scenarios sequentially** — follow the test-lead skill for detailed orchestration:
   - Create TaskCreate entries for all scenarios
   - Spawn one test-executor agent at a time
   - Collect results, update living state doc after each scenario
   - Skip dependent scenarios if their dependency failed
   - Handle idle detection (NO_REPORT / STALLED classification)
   - Shutdown each agent before spawning the next

8. **Update living state doc** — append `## Test Results` run entry

9. **Cleanup**
   - `TeamDelete("test-{slug}")`
   - Delete `.project-orchestrator/state.json`

10. **Present summary** — pass/fail/skipped counts, failure details, next steps
</process>

<success_criteria>
- [ ] All test scenarios executed (or skipped with reason)
- [ ] Test results written to living state doc `## Test Results` section
- [ ] Failure screenshots captured (if `screenshot_on_failure` enabled)
- [ ] Team cleaned up via TeamDelete
- [ ] `.project-orchestrator/state.json` deleted
- [ ] User told next steps
</success_criteria>
