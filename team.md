Manage parallel worker panes for independent tasks.

The team runtime spawns real terminal panes (via tmux or cmux) for true parallel
execution. Use this when tasks are independent and can run simultaneously.

## When to Use

- **Majority voting:** 3 independent Mason implementations running in parallel
- **Independent subtasks:** Frontend + backend + database changes that don't depend on each other
- **Cross-validation:** Same task run on different models or with different approaches

## Setup

Ensure `team.sh` is available in your project:
```bash
cp "$(find ~/.claude -path '*/orca/skills/orchestrate/team.sh' 2>/dev/null | head -1)" .claude/tools/team.sh 2>/dev/null
chmod +x .claude/tools/team.sh
```

## Commands

```bash
# Check what multiplexer is available
bash .claude/tools/team.sh surface

# Spawn a single named worker
bash .claude/tools/team.sh spawn auth-impl 'claude code --message "implement auth module"'

# Spawn 3 parallel workers (majority voting)
bash .claude/tools/team.sh spawn-parallel 3 'claude code --message "implement auth independently"'

# Monitor workers
bash .claude/tools/team.sh status

# Wait for all workers to finish
bash .claude/tools/team.sh wait

# Read a worker's output
bash .claude/tools/team.sh read worker-1

# Kill a runaway worker
bash .claude/tools/team.sh kill worker-2

# Shut everything down
bash .claude/tools/team.sh shutdown
```

## Persistence Loop

Run a task repeatedly until verification passes:
```bash
bash .claude/tools/team.sh loop 'claude code --message "fix the failing tests"' --max-iter 5
```

The loop runs the command, then `bb.py verify`, and repeats if verification
returns DISCONFIRM. Stops on CONFIRM or max iterations.

## Integration with Pipeline

For the orchestrator: when the pipeline reaches majority voting (2+ failed fix
attempts on the same module), use `spawn-parallel 3` instead of sequential
Mason dispatches. After all workers complete, run `bb.py verify` on each
result and select the best.
