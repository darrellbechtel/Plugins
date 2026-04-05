# Orca

A Claude Code plugin that deploys a research-informed multi-agent engineering
pod into any project. Built on Wooldridge's BDI model, updated with empirical
findings from NeurIPS 2025 and sparse communication research.

## Agents

| Agent | Role | When Active |
|-------|------|-------------|
| **Architect** | Design — produces structured blueprints before implementation | Tier 2+ |
| **Mason** | Implementation — writes, refactors, and fixes code against Architect's spec | All tiers |
| **Breaker** | Verification — writes and runs tests, reports structured results | Tier 2+ |
| **Shipp** | Quality gate — lint, format, build checks | Tier 2+ |
| **Sentinel** | Security audit — absolute veto power | Tier 3 |
| **Wiki** | Documentation — READMEs, docstrings, ADRs | Tier 3 |

## Install

```bash
# From GitHub (once published)
/plugin install orca@<your-marketplace>

# From local directory (for development)
claude --plugin-dir /path/to/orca
```

## Setup

After installing, copy the Blackboard CLI into your project:

```bash
mkdir -p .claude/tools
cp "$(find ~/.claude -path '*/orca/skills/orchestrate/bb.py' | head -1)" .claude/tools/bb.py
```

## Usage

### Slash Command

```
/orca:pipeline Add user authentication with bcrypt and JWT
```

This classifies the task, confirms the tier and budget with you, initializes
the Blackboard, and begins dispatching agents.

### Manual

```bash
# Initialize pipeline
python .claude/tools/bb.py init "Add auth endpoint" --tier 3 --budget 60

# Then use @mason, @breaker, @shipp, @sentinel, @wiki in your Claude Code session
```

### Budget Management

```bash
# Check time remaining
python .claude/tools/bb.py budget

# Adjust limits
python .claude/tools/bb.py budget set-agent mason 45
python .claude/tools/bb.py budget set-pipeline 120

# View agent activity
python .claude/tools/bb.py show decisions_log
```

## Architecture

### Blackboard Pattern

Agents communicate through structured JSON (`.claude/blackboard.json`),
never by reading each other's prose output. Each agent has write permissions
only to its designated section.

### Complexity Tiers

| Tier | Agents | Default Budget | Triggers |
|------|--------|---------------|----------|
| 1 — Trivial | Mason | 15m | Single file, <50 LOC |
| 2 — Standard | Architect → Mason → Breaker → Shipp | 45m | Multi-file, new logic |
| 3 — Complex | All 6 | 90m | Security, auth, API, migrations |

### Key Research Findings Applied

- **Debate Martingale (NeurIPS 2025):** Agents don't debate. Breaker reports
  structured test failures. Mason receives targets, not opinions.
- **Sparse Communication:** Agents receive only the Blackboard sections they
  need. No agent reads another agent's full output.
- **Majority Voting > Debate:** After 2 failed fixes, the orchestrator requests
  3 independent implementations and picks the best by test pass rate.
- **Wooldridge 2025 Critique:** The Blackboard provides a structured environment
  layer beyond natural language message-passing.

### Time Budget Enforcement

Every agent checks in via `bb.py checkin` at startup and periodically during
work. The CLI returns `CONTINUE` or `STOP` (exit code 2) based on:

- Pipeline-level deadline
- Per-agent time limits
- Per-agent tool call limits

### Parallel Execution (Team Runtime)

The team runtime (`team.sh`) spawns real terminal panes for true parallel
execution. It auto-detects tmux or cmux — no configuration needed.

```bash
# Majority voting: 3 independent implementations in parallel
bash .claude/tools/team.sh spawn-parallel 3 'claude code --message "implement auth"'

# Monitor workers
bash .claude/tools/team.sh status
bash .claude/tools/team.sh wait

# Read output from a specific worker
bash .claude/tools/team.sh read worker-1
```

### Persistence Loop

Run a task repeatedly until filesystem verification passes:

```bash
bash .claude/tools/team.sh loop 'claude code --message "fix tests"' --max-iter 5
```

The loop runs the command, takes a file snapshot, runs `bb.py verify`,
and retries if verification returns DISCONFIRM.

## File Structure

```
orca/
├── .claude-plugin/
│   └── plugin.json          # Plugin manifest
├── agents/
│   ├── architect.md         # Design agent
│   ├── mason.md             # Implementation agent
│   ├── breaker.md           # Verification agent
│   ├── shipp.md             # Quality gate agent
│   ├── sentinel.md          # Security audit agent
│   └── wiki.md              # Documentation agent
├── skills/
│   └── orchestrate/
│       ├── SKILL.md          # Orchestration rules & protocol
│       ├── bb.py             # Blackboard CLI v2 (structured protocol + verification)
│       └── team.sh           # Parallel execution runtime (tmux/cmux)
├── commands/
│   ├── pipeline.md          # /pipeline slash command
│   └── team.md              # /team slash command
├── hooks/
│   └── hooks.json           # SubagentStop logger
├── setup.sh                 # One-command project setup
├── ARCHITECTURE.md          # Research reference
├── README.md                # Full docs
├── LICENSE                  # MIT
└── .gitignore
```

## Development

Test locally:

```bash
claude --plugin-dir /path/to/orca
```

## License

MIT
