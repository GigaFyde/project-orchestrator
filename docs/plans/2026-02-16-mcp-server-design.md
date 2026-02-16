# Project Orchestrator MCP Server — Design & Implementation

## Status: approved

## Design

### Feature Type
New standalone service (MCP server) + plugin integration

### Services Affected
- New: MCP server (standalone repo or subdirectory)
- Plugin skills: implementer, brainstorming, finishing-branch (replace Dev-MCP stubs with real calls)
- Plugin commands: implement, progress, finish (replace Dev-MCP stubs)
- Plugin config: new `mcp` section in project.yml

### Summary

Build a dedicated MCP server for project-orchestrator that provides **persistent state management, agent coordination, and project intelligence** across sessions and context boundaries. This replaces all the "Dev-MCP" stubs currently scattered across the plugin's skills with a real, purpose-built server.

The server exposes MCP tools that Claude Code agents call during brainstorm, implement, and review phases. It runs as a local process (stdio transport for Claude Code) with file-based persistence.

**Non-goal:** This is NOT a cloud service. It's a local MCP server that runs alongside Claude Code, like the Obsidian MCP server we studied. No auth, no multi-user (yet), no external hosting.

---

### Architecture Overview

```
┌──────────────────────────────────────────────┐
│  Claude Code                                  │
│  ┌─────────────┐  ┌─────────────────────────┐│
│  │ Brainstorm   │  │ Implement team          ││
│  │ skill/agents │  │ (parallel agents)       ││
│  └──────┬───────┘  └──────────┬──────────────┘│
│         │    MCP tool calls   │               │
└─────────┼─────────────────────┼───────────────┘
          │                     │
    ┌─────▼─────────────────────▼─────┐
    │  project-orchestrator-mcp        │
    │  ┌───────────┐ ┌──────────────┐ │
    │  │ State     │ │ Locks        │ │
    │  │ Manager   │ │ Manager      │ │
    │  ├───────────┤ ├──────────────┤ │
    │  │ Activity  │ │ Features     │ │
    │  │ Tracker   │ │ & Scopes     │ │
    │  ├───────────┤ ├──────────────┤ │
    │  │ Handoff   │ │ Dashboard    │ │
    │  │ Manager   │ │ & Progress   │ │
    │  ├───────────┤ ├──────────────┤ │
    │  │ Learning  │ │ Metrics      │ │
    │  │ Store     │ │ Collector    │ │
    │  ├───────────┤ ├──────────────┤ │
    │  │ Conflict  │ │ Branches     │ │
    │  │ Detector  │ │ & Git        │ │
    │  └───────────┘ └──────────────┘ │
    │         ┌──────────┐            │
    │         │ JSON +   │            │
    │         │ SQLite   │            │
    │         └──────────┘            │
    └─────────────────────────────────┘
```

---

### Tool Coverage Audit

The following tools are referenced across existing plugin skills and commands. Every one must be covered by the MCP server or explicitly deprecated.

| Existing stub | Server tool | Notes |
|---|---|---|
| `save_state` | `save_state` | Tier 1 |
| `load_state` | `load_state` | Tier 1 |
| `delete_state` | `delete_state` | Tier 1 — added `prefix` param for bulk delete |
| `acquire_lock` | `acquire_lock` | Tier 1 — added `wait_timeout_seconds` |
| `release_lock` | `release_lock` | Tier 1 |
| `agent_handoff` | `agent_handoff` | Tier 1 — stores under key `handoff-{from}-to-{to}` |
| `receive_handoff` | `receive_handoff` | Tier 1 — retrieves handoff by recipient |
| `report_activity` | `report_activity` | Tier 1 |
| `list_features` | `list_features` | Tier 1 — used by progress command |
| `feature_progress` | `feature_progress` | Tier 1 — used by progress command |
| `update_feature` | `update_feature` | Tier 1 — update feature status/metadata |
| `get_activity_log` | `get_activity_log` | Tier 1 — read side of `report_activity` |
| `list_branches` | `list_branches` | Tier 1 — used by finish/finishing-branch |
| `create_scope` | `create_scope` | Tier 1 — auto-approve hook support |
| `delete_scope` | `delete_scope` | Tier 1 — auto-approve hook cleanup |
| (new) | `register_tasks` | Tier 1 — bulk-create task records for a feature |
| (new) | `update_task` | Tier 1 — update individual task status/reviews |
| (new) | `get_dashboard` | Tier 2 — aggregated view across features |
| (new) | `detect_conflicts` | Tier 2 — pre-wave collision detection |
| (new) | `get_metrics` | Tier 2 — performance analytics |
| (new) | `record_learning` | Tier 2 — cross-project knowledge |
| (new) | `query_learnings` | Tier 2 — retrieve learnings |
| (new) | `get_review_history` | Tier 2 — review outcome tracking |

---

### MCP Tools — Tier 1: Foundation

These implement the existing Dev-MCP stubs in the plugin's skills and commands.

#### State Management

##### `save_state`

Persist agent state across sessions and compaction.

```
Parameters:
  key: string          # unique key, e.g. "implement-auth-task-3"
  data: object         # arbitrary JSON state
  saved_by: string     # agent name for audit trail
  ttl_seconds?: number # auto-expire (default: 86400 = 24h)

Returns:
  { success: true, key: string, saved_at: ISO timestamp }
```

**Use cases:**
- Mid-task checkpointing (implementer resumes after compaction)
- Brainstorm state (exploration findings survive `/clear`)
- Review progress (partial review results)

##### `load_state`

Retrieve previously saved state.

```
Parameters:
  key?: string         # exact key lookup
  prefix?: string      # prefix match, e.g. "implement-auth-" returns all matching

Returns:
  # exact key: { found: boolean, data?: object, saved_by?: string, saved_at?: string }
  # prefix:    { results: [{ key, data, saved_by, saved_at }] }
```

##### `delete_state`

Clean up state after task completion. Supports single key or bulk prefix deletion.

```
Parameters:
  key?: string         # exact key to delete
  prefix?: string      # delete all keys matching prefix (e.g. "implement-auth-")
  # exactly one of key or prefix must be provided

Returns:
  { success: true, deleted_count: number }
```

#### Lock Management

##### `acquire_lock`

Prevent parallel agents from editing the same files.

```
Parameters:
  files: string[]           # file paths to lock
  agent_id: string          # who's locking
  ttl_seconds?: number      # auto-release (default: 600 = 10min)
  wait?: boolean            # wait for lock or fail immediately (default: false)
  wait_timeout_seconds?: number  # max wait time when wait=true (default: 60)

Returns:
  { granted: boolean, lock_id?: string, contested_by?: string, contested_files?: string[] }
```

**Behavior:**
- Locks are advisory — agents check but aren't blocked at OS level
- TTL prevents orphaned locks from dead agents
- `contested_by` tells the requester who has the lock so they can coordinate
- When `wait: true`, server polls every 2s until lock is available or `wait_timeout_seconds` expires. Returns `{ granted: false, reason: "timeout" }` on expiry.

##### `release_lock`

Release a previously acquired lock.

```
Parameters:
  lock_id: string      # from acquire_lock response

Returns:
  { success: true }
```

#### Handoff Management

##### `agent_handoff`

Transfer structured context between phases. Stores handoff under key `handoff-{from}-to-{to}`.

```
Parameters:
  from: string         # source agent/phase identifier (e.g. "brainstorm-lead")
  to: string           # target agent/phase identifier (e.g. "implement-lead")
  context: object      # structured handoff data (design doc path, services, decisions, gotchas)

Returns:
  { handoff_id: string, key: "handoff-{from}-to-{to}", saved_at: ISO timestamp }
```

**Storage convention:** Handoff is stored as state under key `handoff-{from}-to-{to}`. This means it's also accessible via `load_state(key: "handoff-brainstorm-lead-to-implement-lead")` or `load_state(prefix: "handoff-")`, but `receive_handoff` is the preferred retrieval tool.

##### `receive_handoff`

Retrieve a handoff intended for this agent.

```
Parameters:
  agent_id: string     # recipient agent identifier (e.g. "implement-lead")

Returns:
  { found: boolean, from?: string, context?: object, saved_at?: string }
```

**Behavior:** Searches for any handoff where `to` matches `agent_id`. Returns the most recent match. Older handoffs to the same recipient are shadowed (still stored, but not returned). Does not delete the handoff (caller can `delete_state` if cleanup is needed, or `delete_state(prefix: "handoff-")` to clear all).

#### Activity Tracking

##### `report_activity`

Log lifecycle events for timeline tracking.

```
Parameters:
  action: string       # event type: "started_brainstorm", "task_completed", "review_passed", etc.
  feature: string      # feature slug
  agent?: string       # which agent
  details?: object     # event-specific payload

Returns:
  { timestamp: ISO string }
```

##### `get_activity_log`

Query the activity log for a feature.

```
Parameters:
  feature: string      # feature slug
  action?: string      # filter by action type
  agent?: string       # filter by agent
  limit?: number       # max results (default: 20)
  since?: ISO string   # only events after this time

Returns:
  {
    events: [{
      timestamp: ISO string,
      action: string,
      feature: string,
      agent?: string,
      details?: object
    }]
  }
```

#### Feature Management

**Status values:** Features progress through: `brainstorming` → `designing` → `implementing` → `reviewing` → `complete`. The meta-status `"active"` is a filter shorthand meaning "any status except `complete`" (i.e., `brainstorming`, `designing`, `implementing`, `reviewing`).

##### `list_features`

List tracked features with optional status filtering.

```
Parameters:
  status?: string      # filter: "active" (= not complete) | "brainstorming" | "designing" | "implementing" | "reviewing" | "complete"
  project?: string     # filter by project name

Returns:
  {
    features: [{
      slug: string,
      status: string,
      project: string,
      design_doc: string,    # path to design doc
      created_at: ISO string,
      updated_at: ISO string
    }]
  }
```

##### `feature_progress`

Get detailed progress for a single feature.

```
Parameters:
  slug: string         # feature slug

Returns:
  {
    slug: string,
    status: string,
    design_doc: string,
    tasks_total: number,
    tasks_completed: number,
    tasks_in_progress: number,
    tasks_pending: number,
    active_agents: string[],
    current_wave: number,
    blockers: string[],
    last_activity: ISO string,
    tasks: [{
      id: string,
      title: string,
      service: string,
      status: string,
      assignee?: string,
      spec_review?: string,
      quality_review?: string,
      fix_iterations: number
    }]
  }
```

##### `update_feature`

Update feature status or metadata.

```
Parameters:
  slug: string         # feature slug
  status?: string      # new status
  design_doc?: string  # update design doc path
  metadata?: object    # arbitrary metadata merge

Returns:
  { success: true, updated_at: ISO string }
```

##### `register_tasks`

Bulk-create task records for a feature. Called once by the implement lead when implementation starts, using the task table from the design doc.

```
Parameters:
  feature: string      # feature slug
  tasks: [{
    id: string         # task number/id (e.g. "1", "2")
    title: string      # task description
    service: string    # affected service
    wave?: number      # which wave this task belongs to
    files?: string[]   # expected files to edit (for conflict detection)
  }]

Returns:
  { success: true, tasks_created: number }
```

**Behavior:** Replaces any existing tasks for this feature (idempotent — safe to re-call if restarting implementation). Task records start with `status: "pending"`, no assignee, no reviews.

##### `update_task`

Update an individual task's status, assignee, or review results. Called by implementer agents and review skills as work progresses.

```
Parameters:
  feature: string      # feature slug
  task_id: string      # task id
  status?: string      # "pending" | "in_progress" | "complete" | "blocked"
  assignee?: string    # agent name
  spec_review?: string # "pass" | "fail" | "pending"
  quality_review?: string # "pass" | "fail" | "pending"
  fix_iterations?: number # increment fix count
  blockers?: string[]  # blocking issues

Returns:
  { success: true, updated_at: ISO string }
```

**Data flow:** `register_tasks` populates the task table → implementer agents call `update_task` as they work → `feature_progress` reads the aggregated result. This is how `feature_progress` gets its rich per-task data.

#### Scope Management

##### `create_scope`

Create a scope file for auto-approve hooks. This is an integration point for projects that use permission hooks — the scope file tells the hook which files/services are in play for the current implementation wave.

```
Parameters:
  team: string         # team name
  services: string[]   # affected service names
  wave: number         # current wave number
  tasks?: string[]     # task descriptions for context

Returns:
  { success: true, scope_file: string }
```

**Behavior:** Writes a scope file to `.claude/orchestrator-scope.json` in the project directory. The file contains the team, services, wave, and timestamp. Auto-approve hooks can read this to decide whether to permit tool calls.

##### `delete_scope`

Clean up scope file after implementation completes.

```
Parameters:
  (none)               # deletes the active scope file

Returns:
  { success: true, deleted: boolean }
```

#### Branch Management

##### `list_branches`

List git branches matching a pattern across repositories.

```
Parameters:
  pattern?: string     # glob pattern, e.g. "feature/*" (default: "feature/*")
  service?: string     # limit to specific service repo
  project_root?: string # project root path (for discovering service repos)

Returns:
  {
    branches: [{
      name: string,
      service: string,      # which service repo
      is_current: boolean,
      last_commit?: string,  # short SHA
      last_message?: string  # commit message
    }]
  }
```

**Behavior:** Runs `git branch --list <pattern>` in each service directory. For monorepos, runs once in the project root. For polyrepos, iterates service directories from project config.

---

### MCP Tools — Tier 2: Intelligence

New capabilities that go beyond what files on disk can provide.

#### `get_dashboard`

Aggregated view across all active features. Combines `list_features` + `feature_progress` into a single high-level summary.

```
Parameters:
  status?: string      # filter by status (default: all active statuses)
  project?: string     # filter by project
  format?: "summary" | "detailed" | "timeline"

Returns (summary):
  {
    features: [{
      slug: string,
      status: string,
      project: string,
      tasks_total: number,
      tasks_completed: number,
      tasks_in_progress: number,
      active_agents: string[],
      current_wave: number,
      last_activity: ISO timestamp,
      blockers: string[]
    }]
  }

Returns (timeline):
  {
    events: [{ timestamp, action, agent, feature, details }]
  }
```

**Value:** Single-call overview for the `/project:progress` command. Combines what would otherwise be `list_features` + N × `feature_progress` calls.

#### `detect_conflicts`

Check for potential file collisions before agents start work.

```
Parameters:
  feature: string      # feature slug
  tasks: [{            # proposed task assignments
    task_id: string,
    agent: string,
    files: string[]    # files this task will edit
  }]

Returns:
  {
    conflicts: [{
      file: string,
      tasks: [string, string],      # task IDs that collide
      agents: [string, string],     # agent names
      recommendation: "sequence" | "isolate" | "safe"
    }],
    safe: boolean       # true if no conflicts detected
  }
```

**File list sourcing:** The implement lead uses `files` from `register_tasks` data, or infers from task descriptions. If file lists aren't available, skip conflict detection — it's advisory, not required.

**Scope:** Detects conflicts within the provided task list only (typically a single wave). Does not check against already-running tasks from previous waves, since waves are sequential (wait for completion before starting next). If parallel waves are added in the future, this tool would need to also query active locks.

**Value:** The implement lead can validate the wave plan before spawning agents. Currently this is manual eyeballing of the task table.

#### `get_metrics`

Aggregate performance metrics.

```
Parameters:
  feature?: string     # specific feature or all
  project?: string     # filter by project
  metric?: string      # specific metric or all
  since?: ISO string   # time range start

Returns:
  {
    features_completed: number,
    avg_tasks_per_feature: number,
    avg_time_per_task_ms: number,
    review_pass_rate: { spec: number, quality: number },  # 0-1
    avg_fix_iterations: number,
    most_changed_files: [{ path, count }],
    agent_utilization: [{ agent, tasks_completed, avg_time_ms }]
  }
```

**Value:** Understand how the orchestrator performs over time. Which tasks take longest? What's the review pass rate? Are fix iterations trending up?

#### `record_learning`

Store cross-project patterns and decisions.

```
Parameters:
  type: "pattern" | "pitfall" | "decision" | "convention"
  project?: string     # project name (from project.yml)
  service?: string     # service name
  content: string      # the learning
  tags?: string[]      # categorization
  source?: string      # where this was learned (feature slug, review, etc.)

Returns:
  { learning_id: string }
```

#### `query_learnings`

Retrieve relevant learnings for current context.

```
Parameters:
  query?: string       # text search
  type?: string        # filter by type
  project?: string     # filter by project
  service?: string     # filter by service
  tags?: string[]      # filter by tags
  limit?: number       # max results (default: 10)

Returns:
  {
    learnings: [{
      id: string,
      type: string,
      content: string,
      tags: string[],
      project: string,
      source: string,
      recorded_at: ISO string
    }]
  }
```

**Value:** Brainstorm explorers query learnings before proposing designs. "Has this pattern been tried before? What pitfalls were found?" Cross-project memory that survives beyond a single repo's CLAUDE.md.

#### `get_review_history`

Track review outcomes over time.

```
Parameters:
  feature?: string
  service?: string
  reviewer_type?: "spec" | "quality"
  result?: "pass" | "fail"
  limit?: number       # default: 20

Returns:
  {
    reviews: [{
      feature: string,
      task: string,
      reviewer_type: string,
      result: string,
      issues: string[],
      fix_iterations: number,
      reviewed_at: ISO string
    }]
  }
```

**Value:** Identify recurring review failures. "Quality reviewer keeps flagging missing error handling in service-X" → feed that into implementer prompts.

---

### Error Response Format

All tools follow the same error pattern. On failure, the tool returns an MCP error result with `isError: true`:

```
{
  content: [{ type: "text", text: JSON.stringify({ error: string, code?: string }) }],
  isError: true
}
```

**Error codes:**
| Code | Meaning |
|------|---------|
| `NOT_FOUND` | Feature, task, state key, or lock not found |
| `CONFLICT` | Lock contested, scope already exists |
| `VALIDATION_ERROR` | Invalid parameters (missing required fields, bad status value) |
| `TIMEOUT` | Lock wait exceeded `wait_timeout_seconds` |
| `INTERNAL_ERROR` | Server-side failure (DB error, file I/O) |

All errors include a human-readable `error` message. Skills treat any MCP error as "unavailable" and skip gracefully.

---

### Persistence

**Split strategy (decided):**

| Data type | Storage | Rationale |
|-----------|---------|-----------|
| State (`save_state`) | JSON files | Human-readable, simple key-value, TTL via file timestamps |
| Locks | JSON files | Short-lived, simple structure, TTL via timestamps |
| Handoffs | JSON files | Same as state, just namespaced differently |
| Scope files | JSON file in project dir | Needs to be readable by hook scripts |
| Features | SQLite | Queryable by status, project; aggregation for dashboard |
| Activity log | SQLite | Append-only, needs filtering by feature/action/time |
| Learnings | SQLite | Full-text search, multi-field filtering |
| Metrics | SQLite | Aggregation queries (AVG, COUNT, GROUP BY) |
| Review history | SQLite | Multi-field filtering, time-range queries |
| Branches | (none — live git queries) | Always reads from git, no caching |

**Storage location:** `~/.project-orchestrator/` (global, cross-project)
```
~/.project-orchestrator/
  config.json          # server config + schema_version
  state/               # save_state JSON files (keyed by feature/task)
  locks/               # active lock JSON files (auto-cleaned by TTL)
  handoffs/            # handoff JSON files
  data.db              # SQLite database (features, activity, learnings, metrics, reviews)
```

**Schema versioning:** `config.json` includes a `schema_version` field (integer, starting at 1). On server startup:
1. Read `config.json` → check `schema_version`
2. If version < current: run migrations sequentially (v1→v2, v2→v3, etc.)
3. If `config.json` doesn't exist: initialize with current schema version
4. Migrations are idempotent — safe to re-run

**Data retention:**
- State and locks: auto-cleaned by TTL (default 24h / 10min)
- Handoffs: cleaned when consumer calls `delete_state`
- Activity log: retained for 90 days, then pruned on server startup
- Learnings: retained indefinitely (this is the knowledge base)
- Metrics: retained for 1 year
- Review history: retained for 1 year
- Future: add a `prune` tool for manual cleanup if needed

---

### MCP Resources (read-only data exposed to clients)

```
resources:
  project-orchestrator://features          # list of active features
  project-orchestrator://features/{slug}   # single feature status + progress
  project-orchestrator://timeline/{slug}   # feature event timeline
  project-orchestrator://metrics           # aggregate metrics
  project-orchestrator://learnings         # all learnings (use query_learnings for filtered)
```

Resources use the `project-orchestrator://` scheme to match the MCP server name and avoid collision with other servers.

---

### Plugin Integration

#### Config in project.yml

```yaml
mcp:
  enabled: true                    # enable MCP server features
  # Per-project overrides (optional):
  state_ttl_seconds: 86400         # override default state TTL
  lock_ttl_seconds: 600            # override default lock TTL
  # Server-level config lives in ~/.project-orchestrator/config.json
```

The server runs globally. Projects opt into using it. Per-project overrides are passed as parameters to tool calls (the skill reads project.yml and includes the overrides).

#### Skill Changes

**Implementer skill (`Dev-MCP Coordination` section):**
- Replace pseudo-code with actual MCP tool call syntax
- Same optional-resilience pattern: "If MCP unavailable, skip"
- No behavioral changes — just real tool names instead of placeholders

**Brainstorming skill:**
- `save_state` / `agent_handoff` become real calls
- Add `query_learnings` call during exploration (step 6a/6b): "Check if there are relevant learnings from past projects"
- Add `report_activity` calls at phase transitions
- Optionally add a `files` column hint to the task table template for `detect_conflicts` support

**Implement command (lead):**
- `receive_handoff` replaces `load_state(prefix: "handoff-")` for picking up brainstorm context
- `register_tasks` called once at start — populates task records from design doc task table
- `create_scope` / `delete_scope` become real calls
- Add `detect_conflicts` call before spawning each wave (when file lists available)
- `update_feature` for status transitions
- After each wave: `record_learning` for any patterns discovered

**Implementer agents (via implementer skill):**
- `update_task` called on task start (`status: "in_progress"`, `assignee: <agent>`)
- `update_task` called on task complete (`status: "complete"`)
- Review skills call `update_task` with `spec_review` / `quality_review` results

**Progress command:**
- `list_features` → `feature_progress` → `get_activity_log` become real calls
- `get_dashboard` as a single-call alternative when available
- Fall back to design doc parsing when MCP unavailable

**Finish command / finishing-branch skill:**
- `list_branches` becomes a real call
- Fall back to manual `git branch --list` when MCP unavailable

**Review skills:**
- After each review: `report_activity(action: "review_passed" | "review_failed", feature, details: { task, reviewer_type, issues })`
- On review failure: check `get_review_history` for recurring patterns, include in fix prompt

---

### Server Distribution

**Options (decide at implementation):**

| Option | Pros | Cons |
|--------|------|------|
| Subdirectory in this repo | Single repo, easy to version together | Adds runtime code to a pure-markdown plugin |
| Separate repo | Clean separation, independent versioning | Two repos to maintain |
| npm package | Easy install (`npx project-orchestrator-mcp`) | Publishing overhead |

**Recommendation:** Separate repo. The plugin stays pure markdown. The MCP server is an optional companion that users install independently. The plugin detects it via MCP tool availability, same as it does now with Dev-MCP stubs.

**Claude Code MCP config (user adds to `.claude/settings.json` or project `.mcp.json`):**
```json
{
  "mcpServers": {
    "project-orchestrator": {
      "command": "npx",
      "args": ["project-orchestrator-mcp"],
      "env": {}
    }
  }
}
```

Or for local development:
```json
{
  "mcpServers": {
    "project-orchestrator": {
      "command": "node",
      "args": ["/path/to/project-orchestrator-mcp/dist/index.js"]
    }
  }
}
```

---

## Implementation Tasks

| # | Task | Component | Status | Assignee | Spec | Quality | Fix Iterations |
|---|------|-----------|--------|----------|------|---------|----------------|
| 1 | Scaffold MCP server project (package.json, tsconfig, MCP SDK, entry point, stdio transport) | server | pending | — | — | — | — |
| 2 | Implement state management tools (save_state, load_state, delete_state with prefix support) | server | pending | — | — | — | — |
| 3 | Implement lock management tools (acquire_lock with wait/timeout, release_lock) | server | pending | — | — | — | — |
| 4 | Implement handoff tools (agent_handoff, receive_handoff) | server | pending | — | — | — | — |
| 5 | Implement activity tools (report_activity, get_activity_log) | server | pending | — | — | — | — |
| 6 | Implement feature management tools (list_features, feature_progress, update_feature, register_tasks, update_task) | server | pending | — | — | — | — |
| 7 | Implement scope tools (create_scope, delete_scope) | server | pending | — | — | — | — |
| 8 | Implement list_branches tool | server | pending | — | — | — | — |
| 9 | Set up SQLite database + schema versioning + migrations | server | pending | — | — | — | — |
| 10 | Implement get_dashboard tool | server | pending | — | — | — | — |
| 11 | Implement detect_conflicts tool | server | pending | — | — | — | — |
| 12 | Implement metrics tools (get_metrics) | server | pending | — | — | — | — |
| 13 | Implement learnings tools (record_learning, query_learnings) | server | pending | — | — | — | — |
| 14 | Implement review history tool (get_review_history) | server | pending | — | — | — | — |
| 15 | Add MCP resources (project-orchestrator:// URIs) | server | pending | — | — | — | — |
| 16 | Implement data retention / pruning logic | server | pending | — | — | — | — |
| 17 | Update implementer skill — replace Dev-MCP stubs | plugin | pending | — | — | — | — |
| 18 | Update brainstorming skill — replace Dev-MCP stubs + add learnings | plugin | pending | — | — | — | — |
| 19 | Update implement command — real handoff, scope, conflict detection | plugin | pending | — | — | — | — |
| 20 | Update progress command — real list_features, feature_progress, get_activity_log | plugin | pending | — | — | — | — |
| 21 | Update finish command + finishing-branch skill — real list_branches | plugin | pending | — | — | — | — |
| 22 | Update review skills — add review history integration | plugin | pending | — | — | — | — |
| 23 | Documentation and config examples | both | pending | — | — | — | — |

### Wave Plan

**Wave 1 — Scaffold (single task):**
- Task 1: Scaffold MCP server project

**Wave 2 — All Tier 1 + SQLite setup (parallel, all independent after scaffold):**
- Task 2: State management
- Task 3: Lock management
- Task 4: Handoff tools
- Task 5: Activity tools
- Task 6: Feature management
- Task 7: Scope tools
- Task 8: list_branches
- Task 9: SQLite + schema versioning

**Wave 3 — Tier 2 intelligence (parallel, depends on Wave 2 for SQLite):**
- Task 10: Dashboard
- Task 11: Conflict detection
- Task 12: Metrics
- Task 13: Learnings
- Task 14: Review history

**Wave 4 — Server finishing (parallel):**
- Task 15: MCP resources (depends on data-producing tools)
- Task 16: Data retention / pruning

**Wave 5 — Plugin integration (parallel, no shared files, depends on server being functional):**
- Task 17: Implementer skill
- Task 18: Brainstorming skill
- Task 19: Implement command
- Task 20: Progress command
- Task 21: Finish command + finishing-branch skill
- Task 22: Review skills

**Wave 6:**
- Task 23: Documentation

## Implementation Log

(empty — implementation not started)

## Decisions & Context

### Key Decisions

1. **Local-first, no cloud** — The server runs alongside Claude Code as a local process. No auth, no multi-user, no network. Just stdio transport. This keeps it simple and privacy-friendly.

2. **Global server, per-project opt-in** — Server state lives in `~/.project-orchestrator/` and works across all projects. Individual projects opt in via `mcp.enabled: true` in project.yml. This enables cross-project learnings.

3. **Separate repo from plugin** — The plugin stays pure markdown with zero runtime dependencies. The MCP server is an optional companion. The plugin detects its presence via MCP tool availability and gracefully degrades (existing "skip if unavailable" pattern).

4. **Split persistence: JSON + SQLite** — JSON files for simple key-value data (state, locks, handoffs) — human-readable, easy to debug. SQLite for queryable data (features, activity, learnings, metrics, reviews) — enables the filtering, aggregation, and full-text search that Tier 2 tools require.

5. **Advisory locks only** — File locks are coordination signals, not OS-level enforcement. Agents check locks and respect them, but nothing prevents a rogue write. This matches the trust model (all agents are cooperative).

6. **TTL on ephemeral data, retention on persistent data** — State/locks/handoffs auto-expire via TTL (24h/10min). Activity log retained 90 days, metrics/reviews 1 year, learnings indefinitely. Pruning runs on server startup.

7. **Learnings are global** — The learning store spans projects. A pattern learned in project-A can inform design in project-B. This is the key value of a persistent server over file-based state.

8. **Schema versioning from day 1** — `config.json` tracks `schema_version`. Migrations run on startup. Prevents data incompatibility across server updates.

9. **Complete tool coverage** — Every Dev-MCP stub referenced across the plugin is covered by a real tool. No gaps, no "we'll add this later" for existing stubs. The 15 existing stubs map 1:1 to server tools, plus 8 new tools (2 Tier 1 for task management, 6 Tier 2 for intelligence).

10. **Flattened wave plan** — After scaffold, all Tier 1 tools are independent and can be built in parallel. Tier 2 tools depend on SQLite setup but are otherwise independent of each other. This maximizes parallelism.

### Gotchas for Implementers

- **stdio transport only for v1** — Claude Code uses stdio to talk to MCP servers. No HTTP needed initially.
- **Tool naming must match skill stubs** — The existing skills reference `save_state`, `acquire_lock`, etc. The MCP tools must use these exact names so the skills work without changes to their call sites.
- **Graceful degradation is non-negotiable** — Every skill has "if MCP unavailable, skip" guards. The server must never be a hard dependency.
- **State keys are namespaced by convention** — Keys like `implement-{slug}-task-{N}` and `handoff-{from}-to-{to}` are conventions, not enforced schemas. The server stores whatever key is given.
- **Lock TTL must be generous** — Implementer agents can take 5+ minutes per task. Default 10min TTL, but allow override.
- **Cross-project data needs project identification** — Learnings and metrics must include project name (from project.yml) to be useful in cross-project queries.
- **Scope files go in project directory** — Unlike other state (in `~/.project-orchestrator/`), scope files are written to `.claude/orchestrator-scope.json` in the project directory so that hook scripts can read them.
- **`list_branches` runs git commands** — This tool shells out to `git branch --list` in service directories. It needs the project root path to discover repos. No caching — always live data.
- **`acquire_lock` wait polling** — When `wait: true`, the server polls every 2s. This happens server-side (the tool call blocks until lock is acquired or timeout). The client just sees a longer response time.
- **`detect_conflicts` file lists are best-effort** — The implement lead infers files from task descriptions. If unavailable, skip conflict detection. It's advisory, not blocking.
