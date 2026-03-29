#!/usr/bin/env bash
#
# multiagent-team setup
# =====================
# Run this in any project to deploy the multi-agent engineering team.
#
# Usage:
#   bash setup.sh                    # Auto-detect plugin location
#   bash setup.sh /path/to/plugin    # Explicit plugin path
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="${1:-$SCRIPT_DIR}"
PROJECT_DIR="$(pwd)"

echo "=== multiagent-team setup ==="
echo "Plugin:  $PLUGIN_DIR"
echo "Project: $PROJECT_DIR"
echo ""

# 1. Create project directories
mkdir -p "$PROJECT_DIR/.claude/tools"

# 2. Copy bb.py (the Blackboard CLI)
if [ -f "$PLUGIN_DIR/skills/orchestrate/bb.py" ]; then
    cp "$PLUGIN_DIR/skills/orchestrate/bb.py" "$PROJECT_DIR/.claude/tools/bb.py"
    echo "✓ Blackboard CLI → .claude/tools/bb.py"
else
    echo "✗ Could not find bb.py in plugin"
    exit 1
fi

# 3. Verify bb.py works
if python3 "$PROJECT_DIR/.claude/tools/bb.py" --help > /dev/null 2>&1; then
    echo "✓ bb.py verified (Python 3)"
else
    echo "✗ bb.py failed — check Python 3 is installed"
    exit 1
fi

# 4. Check if CLAUDE.md exists and offer to append orchestration rules
if [ -f "$PROJECT_DIR/CLAUDE.md" ]; then
    echo ""
    echo "CLAUDE.md already exists in this project."
    echo "You may want to add the orchestration rules manually."
    echo "See: $PLUGIN_DIR/ARCHITECTURE.md for the full reference."
    echo ""
    echo "Quick snippet to append to your CLAUDE.md:"
    echo ""
    echo '  ## Multi-Agent Team'
    echo '  This project uses the multiagent-team plugin.'
    echo '  See /multiagent-team:pipeline to start a pipeline.'
    echo '  Agents: @mason @breaker @shipp @sentinel @wiki'
    echo '  Blackboard: python .claude/tools/bb.py help'
    echo ""
else
    cat > "$PROJECT_DIR/CLAUDE.md" << 'CLAUDE_EOF'
# Project Configuration

## Multi-Agent Team

This project uses the multiagent-team plugin for orchestrated development.

### Quick Start

Start a pipeline:
```
/multiagent-team:pipeline <task description>
```

Or manually:
```bash
python .claude/tools/bb.py init "task description" --tier 2 --budget 45
```

### Agents

- **@mason** — writes code (all tiers)
- **@breaker** — writes and runs tests (tier 2+)
- **@shipp** — lint, format, build checks (tier 2+)
- **@sentinel** — security audit, absolute veto (tier 3)
- **@wiki** — documentation, ADRs (tier 3)

### Orchestration Rules

See the multiagent-team plugin's orchestrate skill for full rules:
- Agents communicate through `.claude/blackboard.json`, never prose
- Classify tasks before dispatching (Tier 1/2/3)
- Breaker reports facts, not opinions (targeted interventions)
- After 2 failed fixes → majority voting (3 independent implementations)
- Sentinel block is absolute — no negotiation
CLAUDE_EOF
    echo "✓ CLAUDE.md created with orchestration rules"
fi

# 5. Add .claude/blackboard.json to .gitignore if not already there
if [ -f "$PROJECT_DIR/.gitignore" ]; then
    if ! grep -q "blackboard.json" "$PROJECT_DIR/.gitignore" 2>/dev/null; then
        echo "" >> "$PROJECT_DIR/.gitignore"
        echo "# Multi-agent blackboard (runtime state)" >> "$PROJECT_DIR/.gitignore"
        echo ".claude/blackboard.json" >> "$PROJECT_DIR/.gitignore"
        echo ".claude/blackboard.tmp" >> "$PROJECT_DIR/.gitignore"
        echo ".claude/blackboard_history/" >> "$PROJECT_DIR/.gitignore"
        echo "✓ Added blackboard files to .gitignore"
    else
        echo "✓ .gitignore already excludes blackboard"
    fi
else
    cat > "$PROJECT_DIR/.gitignore" << 'GI_EOF'
# Multi-agent blackboard (runtime state)
.claude/blackboard.json
.claude/blackboard.tmp
.claude/blackboard_history/
GI_EOF
    echo "✓ Created .gitignore with blackboard exclusions"
fi

echo ""
echo "=== Setup complete ==="
echo ""
echo "Next steps:"
echo "  1. Install the plugin:  claude --plugin-dir $PLUGIN_DIR"
echo "  2. Start a pipeline:    /multiagent-team:pipeline <your task>"
echo "  3. Or manually:         python .claude/tools/bb.py init 'task' --tier 2"
echo ""
echo "Useful commands:"
echo "  python .claude/tools/bb.py show         # View blackboard state"
echo "  python .claude/tools/bb.py budget       # Check time remaining"
echo "  python .claude/tools/bb.py failures     # Show blocking test failures"
echo "  python .claude/tools/bb.py show decisions_log  # View audit trail"
