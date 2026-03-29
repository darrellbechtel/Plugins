Set up the multi-agent pipeline for the task the user describes.

## Steps

1. **Ensure bb.py is available.** If `.claude/tools/bb.py` does not exist in the project, copy it from the plugin:
   ```bash
   mkdir -p .claude/tools
   cp "$(find ~/.claude -path '*/multiagent-team/skills/orchestrate/bb.py' 2>/dev/null | head -1)" .claude/tools/bb.py 2>/dev/null
   ```
   If that doesn't work, tell the user to run: `cp <plugin-path>/skills/orchestrate/bb.py .claude/tools/bb.py`

2. **Classify the task** the user provided into a complexity tier:
   - **Tier 1 (Trivial):** Single file, <50 LOC, no deps, no security
   - **Tier 2 (Standard):** Multi-file OR new logic OR tests needed
   - **Tier 3 (Complex):** Security, auth, API, migrations, cross-cutting

3. **Ask the user** to confirm the tier and time budget (show defaults: Tier 1=15m, Tier 2=45m, Tier 3=90m)

4. **Initialize the Blackboard:**
   ```bash
   python .claude/tools/bb.py init "<task description>" --tier <N> --budget <M>
   ```

5. **Begin dispatching agents** per the tier:
   - Tier 1: Use @mason only
   - Tier 2: @architect → @mason → @breaker → @shipp
   - Tier 3: @architect → @mason → @breaker → @shipp → @sentinel → @wiki

6. Follow the orchestration rules in the `orchestrate` skill for sparse communication, conflict resolution, and budget enforcement.
