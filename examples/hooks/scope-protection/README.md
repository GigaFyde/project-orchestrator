# Scope Protection Hook (Example)

Prevents teammates from editing files outside their assigned scope during parallel implementation.

## Setup

1. Copy `hooks.json` into your project's `.claude/hooks/` or merge with your existing hooks config.
2. Copy `scope-protection.sh` to your project's `scripts/` directory.
3. Create scope files for each team at `.claude/hooks/scopes/{team}.json`.
4. Make the script executable: `chmod +x scripts/scope-protection.sh`

## Scope File Format

Create `.claude/hooks/scopes/{team}.json` where `{team}` matches your implementation team name (e.g., `implement-my-feature`):

```json
{
  "agent-1": ["src/api/", "src/api/**"],
  "agent-2": ["src/frontend/", "src/frontend/**"],
  "shared": ["package.json", "tsconfig.json"]
}
```

Each key is a teammate name. The value is an array of allowed path prefixes. A file edit is allowed if the file path starts with any of the agent's allowed prefixes, or any path listed under `"shared"`.

## How It Works

- Fires on every `Edit` and `Write` tool call (PreToolUse event)
- Reads the scope file for the current team from `.claude/orchestrator-state.json`
- Checks if the file being edited is within the agent's allowed paths
- Blocks the edit with a reason if the file is out of scope
- If no scope file exists, the hook is a no-op (allows all edits)

## Limitations

- Path matching is prefix-based, not glob-based
- Scope files must be manually created before implementation starts
- The `shared` key is conventional — any agent can edit shared paths
