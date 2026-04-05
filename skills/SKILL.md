# Orchestrate Skill — Multi-Agent Pipeline Management

This skill is automatically invoked when Claude detects a task that would
benefit from multi-agent orchestration. It provides the routing rules,
Blackboard protocol, and conflict resolution procedures.

## When to Use This Skill

Invoke this skill when:
- A task requires code implementation AND verification
- Security-sensitive changes are being made
- The user mentions agents, pipeline, or team
- A task matches Tier 2 or Tier 3 complexity

## Blackboard CLI

The Blackboard is at `.claude/blackboard.json`. All agents interact through
the `bb.py` CLI tool. The tool is bundled with this plugin at:

```bash
python "$(dirname "$(claude plugins path multiagent-team)")/skills/orchestrate/bb.py"
```

Or copy it into your project for easier access:
```bash
cp "$(dirname "$(claude plugins path multiagent-team)")/skills/orchestrate/bb.py" .claude/tools/bb.py
```

### Quick Reference

```bash
# Initialize pipeline
python .claude/tools/bb.py init "task description" --tier 2 --budget 45

# Agent check-in (returns CONTINUE or STOP)
python .claude/tools/bb.py checkin mason "starting work"

# Update sections
python .claude/tools/bb.py update codebase_state '{"files_modified": ["src/app.py"]}'
python .claude/tools/bb.py update test_results '{"total_tests": 5, "passed": 5, "failed": 0}'
python .claude/tools/bb.py update quality_gate '{"status": "pass", "lint_score": 9.1}'
python .claude/tools/bb.py update security_gate '{"status": "pass"}'

# Log decisions
python .claude/tools/bb.py log mason implement "files=src/app.py"

# View state
python .claude/tools/bb.py show
python .claude/tools/bb.py show decisions_log
python .claude/tools/bb.py budget
python .claude/tools/bb.py failures
```

## Complexity Classification

| Tier | Agents | Criteria | Default Budget |
|------|--------|----------|---------------|
| 1 — Trivial | @mason | Single file, <50 LOC, no deps | 15m |
| 2 — Standard | @architect → @mason → @breaker → @shipp | Multi-file OR new logic | 45m |
| 3 — Complex | @architect → @mason → @breaker → @shipp → @sentinel → @wiki | Security, API, migrations | 90m |

**Tier 3 triggers:** auth, login, password, token, jwt, oauth, session,
csrf, xss, injection, encrypt, secret, credential, migration, database,
schema, breaking, api

## Dispatch Protocol

1. Classify complexity tier
2. Run `bb.py init` with tier and budget
3. Dispatch agents sequentially per tier:
   - Tier 2+: @architect explores codebase, writes `design_spec` to Blackboard
   - @mason reads `design_spec` and implements against it
   - @breaker verifies, @shipp checks quality
   - Tier 3: @sentinel audits security, @wiki documents
4. Each agent calls `checkin` at start and every ~10 tool calls
5. Each agent reads/writes Blackboard, never reads other agents' prose

## Sparse Communication

- @architect gets: task description + reads existing codebase directly
- @mason gets: design spec + task + codebase state + failing test TARGETS
- @breaker gets: modified file list ONLY (not Mason's reasoning)
- @shipp gets: file list + test count ONLY
- @sentinel gets: full codebase state + quality gate + decision log
- @wiki gets: file list + full decision log

## Conflict Resolution

1. Sentinel block → absolute veto, Mason applies fix constraint
2. Breaker failure → send ONLY test targets to Mason (no opinions)
3. After 2 failed fixes → 3 independent implementations via `team.sh spawn-parallel` (majority voting)
4. Sentinel blocks 3+ → escalate to human

## Parallel Execution (Team Runtime)

The team runtime (`team.sh`) spawns real terminal panes for true parallel
execution. It auto-detects tmux or cmux.

```bash
# Check available surface
bash .claude/tools/team.sh surface

# Majority voting: 3 independent Mason implementations
bash .claude/tools/team.sh spawn-parallel 3 'claude code --message "implement auth"'

# Monitor and wait
bash .claude/tools/team.sh status
bash .claude/tools/team.sh wait
```

Use parallel execution when:
- Majority voting is triggered (2+ failed fix attempts)
- Tier 3 task decomposes into independent subtasks
- Cross-validation across different approaches

Do NOT use parallel execution when:
- Tasks are dependent (Architect must finish before Mason starts)
- Simple Tier 1 tasks (overhead not worth it)

## Persistence Loop

The loop runs a task repeatedly until `bb.py verify` confirms success:

```bash
bash .claude/tools/team.sh loop 'claude code --message "fix tests"' --max-iter 5
```

The loop: run command → snapshot files → verify → if DISCONFIRM, retry.
Stops on CONFIRM, no blocking failures, or max iterations.

Use this for tasks that need iterative refinement without human intervention.
The time budget (`bb.py budget`) still applies — the loop respects pipeline
deadlines.
