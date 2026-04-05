#!/usr/bin/env bash
#
# team.sh — Parallel Execution Runtime for multiagent-team
# =========================================================
#
# Multiplexer-agnostic worker management. Detects tmux, cmux, or plain
# terminal and spawns parallel Claude Code sessions accordingly.
#
# Usage:
#   team.sh spawn <worker-name> <command>     Spawn a worker in a new pane
#   team.sh spawn-parallel <n> <command>      Spawn N workers with same task
#   team.sh status                            Show all active workers
#   team.sh wait [worker-name]                Wait for worker(s) to complete
#   team.sh read <worker-name>                Capture worker pane output
#   team.sh kill <worker-name>                Kill a specific worker
#   team.sh shutdown                          Kill all workers
#   team.sh surface                           Detect and report current surface
#   team.sh loop <command> [--max-iter N]     Persistence loop until success
#
# Environment:
#   TEAM_SURFACE=tmux|cmux|auto    Force a specific surface (default: auto)
#   TEAM_STATE_DIR=<path>          State directory (default: .claude/team)
#   TEAM_PROJECT_DIR=<path>        Project root (default: cwd)
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TEAM_SURFACE="${TEAM_SURFACE:-auto}"
TEAM_PROJECT_DIR="${TEAM_PROJECT_DIR:-$(pwd)}"
TEAM_STATE_DIR="${TEAM_STATE_DIR:-$TEAM_PROJECT_DIR/.claude/team}"
BB_CMD="python3 $TEAM_PROJECT_DIR/.claude/tools/bb.py"

EVENTS_FILE="${TEAM_PROJECT_DIR}/.claude/events.jsonl"
ALERT_KEYWORDS="${ALERT_KEYWORDS:-error|Error|ERROR|FAIL|fail|panic|PANIC|Traceback|segfault}"
STALE_THRESHOLD_MIN="${STALE_THRESHOLD_MIN:-10}"

mkdir -p "$TEAM_STATE_DIR"

# ---------------------------------------------------------------------------
# Event Emitter (mirrors bb.py emit — writes to same event log + webhooks)
# ---------------------------------------------------------------------------

_emit_event() {
    local event_type="$1"; shift
    local ts
    ts=$(python3 -c "import time; print(time.time())")
    local json_data="{\"ts\": $ts, \"type\": \"$event_type\""
    while [ $# -ge 2 ]; do
        json_data="$json_data, \"$1\": \"$2\""
        shift 2
    done
    json_data="$json_data}"
    mkdir -p "$(dirname "$EVENTS_FILE")"
    echo "$json_data" >> "$EVENTS_FILE" 2>/dev/null || true
    # Forward to any MULTIAGENT_WEBHOOK_* sinks
    _forward_webhooks "$event_type" "$json_data"
}

_forward_webhooks() {
    local event_type="$1" json_data="$2"
    env | grep '^MULTIAGENT_WEBHOOK_' | while IFS='=' read -r key url; do
        local payload
        payload=$(printf '{"text": "*[%s]* %s"}' "$event_type" "$(echo "$json_data" | python3 -c "
import json,sys
d=json.load(sys.stdin)
parts=[f\"{k}={v}\" for k,v in d.items() if k not in ('ts','type')]
print(', '.join(parts[:5]))" 2>/dev/null || echo "")")
        curl -s -X POST -H 'Content-Type: application/json' -d "$payload" "$url" >/dev/null 2>&1 &
    done
}

# ---------------------------------------------------------------------------
# Surface Detection
# ---------------------------------------------------------------------------

detect_surface() {
    if [ "$TEAM_SURFACE" != "auto" ]; then
        echo "$TEAM_SURFACE"
        return
    fi

    # Check cmux first (socket-based)
    if [ -S "/tmp/cmux.sock" ] && command -v cmux &>/dev/null; then
        echo "cmux"
    # Check if inside tmux
    elif [ -n "${TMUX:-}" ]; then
        echo "tmux"
    # Check if tmux is available (can create detached sessions)
    elif command -v tmux &>/dev/null; then
        echo "tmux-detached"
    else
        echo "none"
    fi
}

SURFACE=$(detect_surface)

# ---------------------------------------------------------------------------
# Worker State Management
# ---------------------------------------------------------------------------

worker_state_file() {
    echo "$TEAM_STATE_DIR/$1.json"
}

write_worker_state() {
    local name="$1" pid="$2" surface="$3" surface_id="$4" status="$5" cmd="$6"
    cat > "$(worker_state_file "$name")" << EOF
{
  "name": "$name",
  "pid": $pid,
  "surface": "$surface",
  "surface_id": "$surface_id",
  "status": "$status",
  "command": $(printf '%s' "$cmd" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'),
  "started_at": $(date +%s),
  "project_dir": "$TEAM_PROJECT_DIR"
}
EOF
}

read_worker_state() {
    local name="$1"
    local state_file
    state_file="$(worker_state_file "$name")"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "{}"
    fi
}

update_worker_status() {
    local name="$1" new_status="$2"
    local state_file
    state_file="$(worker_state_file "$name")"
    if [ -f "$state_file" ]; then
        python3 -c "
import json, sys
with open('$state_file', 'r') as f:
    state = json.load(f)
state['status'] = '$new_status'
state['finished_at'] = $(date +%s)
with open('$state_file', 'w') as f:
    json.dump(state, f, indent=2)
"
    fi
}

list_workers() {
    for f in "$TEAM_STATE_DIR"/*.json; do
        [ -f "$f" ] || continue
        basename "$f" .json
    done
}

# ---------------------------------------------------------------------------
# Surface Operations — tmux
# ---------------------------------------------------------------------------

tmux_spawn() {
    local name="$1" cmd="$2"
    local session_name="mat-${name}"  # multiagent-team prefix

    if [ "$SURFACE" = "tmux" ]; then
        # Inside tmux: split pane
        tmux split-window -h -t "$TMUX_PANE" \
            "cd $TEAM_PROJECT_DIR && $cmd; echo '[WORKER:$name:DONE]' > $TEAM_STATE_DIR/${name}.done"
        local pane_id
        pane_id=$(tmux display-message -p '#{pane_id}' -t '!')
        write_worker_state "$name" "0" "tmux" "$pane_id" "running" "$cmd"
        echo "$pane_id"
    else
        # Outside tmux: create detached session
        tmux new-session -d -s "$session_name" -c "$TEAM_PROJECT_DIR" \
            "$cmd; echo '[WORKER:$name:DONE]' > $TEAM_STATE_DIR/${name}.done"
        write_worker_state "$name" "0" "tmux-detached" "$session_name" "running" "$cmd"
        echo "$session_name"
    fi
}

tmux_read() {
    local name="$1"
    local state
    state=$(read_worker_state "$name")
    local surface_id
    surface_id=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface_id',''))")
    local surface_type
    surface_type=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface',''))")

    if [ "$surface_type" = "tmux" ]; then
        tmux capture-pane -p -t "$surface_id" 2>/dev/null || echo "[pane closed]"
    elif [ "$surface_type" = "tmux-detached" ]; then
        tmux capture-pane -p -t "${surface_id}:0.0" 2>/dev/null || echo "[session closed]"
    fi
}

tmux_kill() {
    local name="$1"
    local state
    state=$(read_worker_state "$name")
    local surface_id
    surface_id=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface_id',''))")
    local surface_type
    surface_type=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface',''))")

    if [ "$surface_type" = "tmux" ]; then
        tmux kill-pane -t "$surface_id" 2>/dev/null || true
    elif [ "$surface_type" = "tmux-detached" ]; then
        tmux kill-session -t "$surface_id" 2>/dev/null || true
    fi
    update_worker_status "$name" "killed"
}

tmux_is_alive() {
    local name="$1"
    # Check for completion marker
    if [ -f "$TEAM_STATE_DIR/${name}.done" ]; then
        return 1  # Not alive — completed
    fi

    local state
    state=$(read_worker_state "$name")
    local surface_id
    surface_id=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface_id',''))")
    local surface_type
    surface_type=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface',''))")

    if [ "$surface_type" = "tmux" ]; then
        tmux has-session -t "$surface_id" 2>/dev/null
    elif [ "$surface_type" = "tmux-detached" ]; then
        tmux has-session -t "$surface_id" 2>/dev/null
    else
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Surface Operations — cmux
# ---------------------------------------------------------------------------

cmux_spawn() {
    local name="$1" cmd="$2"

    # Split right to create a new pane
    local surface_id
    surface_id=$(cmux split right 2>/dev/null | grep -oE 'surface:[0-9]+' | head -1 || echo "surface:unknown")

    # Send the command to the new pane
    cmux send --surface "$surface_id" \
        "cd $TEAM_PROJECT_DIR && $cmd; echo '[WORKER:$name:DONE]' > $TEAM_STATE_DIR/${name}.done" 2>/dev/null

    write_worker_state "$name" "0" "cmux" "$surface_id" "running" "$cmd"
    echo "$surface_id"
}

cmux_read() {
    local name="$1"
    local state
    state=$(read_worker_state "$name")
    local surface_id
    surface_id=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface_id',''))")

    cmux send --surface "$surface_id" --capture 2>/dev/null || echo "[pane closed]"
}

cmux_kill() {
    local name="$1"
    local state
    state=$(read_worker_state "$name")
    local surface_id
    surface_id=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('surface_id',''))")

    cmux close --surface "$surface_id" 2>/dev/null || true
    update_worker_status "$name" "killed"
}

cmux_is_alive() {
    local name="$1"
    if [ -f "$TEAM_STATE_DIR/${name}.done" ]; then
        return 1
    fi
    # cmux doesn't have a clean "is pane alive" check yet
    # Fall back to checking for completion marker
    return 0
}

# ---------------------------------------------------------------------------
# Unified Surface Dispatch
# ---------------------------------------------------------------------------

spawn_worker() {
    local name="$1" cmd="$2"
    case "$SURFACE" in
        tmux|tmux-detached) tmux_spawn "$name" "$cmd" ;;
        cmux)               cmux_spawn "$name" "$cmd" ;;
        none)
            echo "ERROR: No multiplexer available."
            echo "Install tmux (brew install tmux) or cmux (brew install --cask cmux)"
            exit 1
            ;;
    esac
}

read_worker() {
    local name="$1"
    case "$SURFACE" in
        tmux|tmux-detached) tmux_read "$name" ;;
        cmux)               cmux_read "$name" ;;
        none)               echo "[no surface]" ;;
    esac
}

kill_worker() {
    local name="$1"
    case "$SURFACE" in
        tmux|tmux-detached) tmux_kill "$name" ;;
        cmux)               cmux_kill "$name" ;;
        none)               true ;;
    esac
}

is_worker_alive() {
    local name="$1"
    case "$SURFACE" in
        tmux|tmux-detached) tmux_is_alive "$name" ;;
        cmux)               cmux_is_alive "$name" ;;
        none)               return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_surface() {
    echo "Surface: $SURFACE"
    case "$SURFACE" in
        tmux)          echo "Mode: inside tmux session (split panes)" ;;
        tmux-detached) echo "Mode: tmux available (detached sessions)" ;;
        cmux)          echo "Mode: cmux socket detected (native panes)" ;;
        none)          echo "Mode: no multiplexer (install tmux or cmux)" ;;
    esac
    echo "State dir: $TEAM_STATE_DIR"
    echo "Project: $TEAM_PROJECT_DIR"
}

cmd_spawn() {
    if [ $# -lt 2 ]; then
        echo "Usage: team.sh spawn <worker-name> <command>"
        exit 1
    fi
    local name="$1"
    shift
    local cmd="$*"

    echo "Spawning worker '$name' on $SURFACE..."
    local surface_id
    surface_id=$(spawn_worker "$name" "$cmd")
    echo "Worker '$name' started (surface: $surface_id)"

    # Log to blackboard + event stream
    $BB_CMD log orchestrator spawn_worker "worker=$name, surface=$SURFACE" 2>/dev/null || true
    _emit_event "worker.started" "worker" "$name" "surface" "$SURFACE"
}

cmd_spawn_parallel() {
    if [ $# -lt 2 ]; then
        echo "Usage: team.sh spawn-parallel <count> <command>"
        echo "Example: team.sh spawn-parallel 3 'claude code --message \"implement auth\"'"
        exit 1
    fi
    local count="$1"
    shift
    local cmd="$*"

    echo "Spawning $count parallel workers on $SURFACE..."
    for i in $(seq 1 "$count"); do
        local name="worker-${i}"
        local surface_id
        surface_id=$(spawn_worker "$name" "$cmd")
        echo "  Worker $i/$count started ($surface_id)"
        sleep 1  # Brief pause to avoid race conditions
    done

    $BB_CMD log orchestrator spawn_parallel "count=$count, surface=$SURFACE" 2>/dev/null || true
    _emit_event "team.spawn_parallel" "count" "$count" "surface" "$SURFACE"
    echo "All $count workers spawned. Use 'team.sh status' to monitor."
}

cmd_status() {
    echo "=== Team Status ($SURFACE) ==="
    echo ""

    local active=0 completed=0 failed=0

    for name in $(list_workers); do
        local state
        state=$(read_worker_state "$name")
        local status cmd started
        status=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status','unknown'))" 2>/dev/null)
        cmd=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('command','?')[:60])" 2>/dev/null)
        started=$(echo "$state" | python3 -c "import json,sys; import time; t=json.load(sys.stdin).get('started_at',0); print(f'{(time.time()-t)/60:.1f}m ago')" 2>/dev/null)

        # Check if done marker exists
        if [ -f "$TEAM_STATE_DIR/${name}.done" ]; then
            if [ "$status" = "running" ]; then
                update_worker_status "$name" "completed"
                status="completed"
            fi
        fi

        local indicator
        case "$status" in
            running)   indicator="⟳"; active=$((active + 1)) ;;
            completed) indicator="✓"; completed=$((completed + 1)) ;;
            killed)    indicator="✗"; failed=$((failed + 1)) ;;
            *)         indicator="?"; ;;
        esac

        printf "  %s %-15s [%-9s] %s (%s)\n" "$indicator" "$name" "$status" "$cmd" "$started"
    done

    if [ $((active + completed + failed)) -eq 0 ]; then
        echo "  No workers."
    fi

    echo ""
    echo "Active: $active | Completed: $completed | Failed: $failed"
}

cmd_wait() {
    local target="${1:-all}"
    local poll_interval=5
    local timeout=3600  # 1 hour max wait

    echo "Waiting for ${target} to complete (polling every ${poll_interval}s)..."

    local start
    start=$(date +%s)

    while true; do
        local all_done=true

        for name in $(list_workers); do
            if [ "$target" != "all" ] && [ "$target" != "$name" ]; then
                continue
            fi

            if [ -f "$TEAM_STATE_DIR/${name}.done" ]; then
                update_worker_status "$name" "completed"
                continue
            fi

            if is_worker_alive "$name" 2>/dev/null; then
                all_done=false
            else
                # Worker died without completion marker
                update_worker_status "$name" "failed"
            fi
        done

        if $all_done; then
            echo "All target workers completed."
            $BB_CMD log orchestrator workers_completed "target=$target" 2>/dev/null || true
            _emit_event "team.all_completed" "target" "$target"
            return 0
        fi

        local elapsed=$(( $(date +%s) - start ))
        if [ $elapsed -gt $timeout ]; then
            echo "TIMEOUT: Workers still running after ${timeout}s"
            return 1
        fi

        sleep "$poll_interval"
    done
}

cmd_read() {
    if [ $# -lt 1 ]; then
        echo "Usage: team.sh read <worker-name>"
        exit 1
    fi
    read_worker "$1"
}

cmd_kill() {
    if [ $# -lt 1 ]; then
        echo "Usage: team.sh kill <worker-name>"
        exit 1
    fi
    kill_worker "$1"
    echo "Worker '$1' killed."
}

cmd_shutdown() {
    echo "Shutting down all workers..."
    for name in $(list_workers); do
        local state
        state=$(read_worker_state "$name")
        local status
        status=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        if [ "$status" = "running" ]; then
            kill_worker "$name"
            echo "  Killed: $name"
        fi
    done
    echo "All workers shut down."
    $BB_CMD log orchestrator shutdown "all workers terminated" 2>/dev/null || true
    _emit_event "team.shutdown"
}

cmd_loop() {
    # Persistence/completion loop — runs the pipeline until verify passes
    if [ $# -lt 1 ]; then
        echo "Usage: team.sh loop '<pipeline-command>' [--max-iter N]"
        echo ""
        echo "Runs the command, then 'bb.py verify'. If verify returns DISCONFIRM,"
        echo "re-runs the command. Repeats until CONFIRM or max iterations."
        echo ""
        echo "Example:"
        echo "  team.sh loop 'claude code --message \"fix the auth module\"' --max-iter 5"
        exit 1
    fi

    local cmd="$1"
    shift
    local max_iter=5

    while [ $# -gt 0 ]; do
        case "$1" in
            --max-iter) max_iter="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    echo "=== Persistence Loop ==="
    echo "Command: $cmd"
    echo "Max iterations: $max_iter"
    echo ""

    $BB_CMD log orchestrator loop_start "max_iter=$max_iter" 2>/dev/null || true

    for iter in $(seq 1 "$max_iter"); do
        echo "--- Iteration $iter/$max_iter ---"

        # Run the command
        echo "Running task..."
        eval "$cmd" || true

        # Snapshot current files if needed
        $BB_CMD snapshot --git 2>/dev/null || true

        # Verify
        echo ""
        echo "Verifying..."
        local verify_output
        verify_output=$($BB_CMD verify 2>&1) || true
        echo "$verify_output"

        # Check if verify passed
        if echo "$verify_output" | grep -q "\[CONFIRM\]"; then
            echo ""
            echo "=== LOOP COMPLETE: All claims verified (iteration $iter) ==="
            $BB_CMD log orchestrator loop_complete "iterations=$iter, result=CONFIRMED" 2>/dev/null || true
            _emit_event "loop.complete" "iterations" "$iter" "result" "CONFIRMED"
            return 0
        fi

        # Check blackboard for blocking failures
        local blocking
        blocking=$($BB_CMD failures 2>&1) || true
        if echo "$blocking" | grep -q "No blocking failures"; then
            echo ""
            echo "=== LOOP COMPLETE: No blocking failures (iteration $iter) ==="
            $BB_CMD log orchestrator loop_complete "iterations=$iter, result=no_blockers" 2>/dev/null || true
            return 0
        fi

        if [ "$iter" -lt "$max_iter" ]; then
            echo ""
            echo "Issues found. Re-running (iteration $((iter + 1))/$max_iter)..."
            $BB_CMD log orchestrator loop_retry "iteration=$iter, retrying" 2>/dev/null || true
            sleep 2
        fi
    done

    echo ""
    echo "=== LOOP EXHAUSTED: Max iterations ($max_iter) reached ==="
    echo "Action: Review manually or increase --max-iter"
    $BB_CMD log orchestrator loop_exhausted "max_iter=$max_iter" 2>/dev/null || true
    _emit_event "loop.exhausted" "max_iter" "$max_iter"
    return 1
}

cmd_clean() {
    echo "Cleaning team state..."
    rm -rf "$TEAM_STATE_DIR"/*.json "$TEAM_STATE_DIR"/*.done
    echo "Team state cleared."
}

# ---------------------------------------------------------------------------
# Monitoring — Keyword Scanning + Staleness Detection
# ---------------------------------------------------------------------------

cmd_scan() {
    # Scan all running workers for alert keywords in new pane output
    local found=0
    for name in $(list_workers); do
        local state
        state=$(read_worker_state "$name")
        local status
        status=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        [ "$status" = "running" ] || continue

        local output
        output=$(read_worker "$name" 2>/dev/null) || continue
        local last_scan="$TEAM_STATE_DIR/${name}.lastscan"
        local prev=""
        [ -f "$last_scan" ] && prev=$(cat "$last_scan")

        # Diff to find new lines only
        local new_lines
        new_lines=$(diff <(echo "$prev") <(echo "$output") 2>/dev/null | grep '^>' | sed 's/^> //' || true)
        echo "$output" > "$last_scan"

        if [ -n "$new_lines" ] && echo "$new_lines" | grep -qE "$ALERT_KEYWORDS"; then
            local match
            match=$(echo "$new_lines" | grep -E "$ALERT_KEYWORDS" | tail -1)
            echo "ALERT [$name]: $match"
            _emit_event "worker.keyword_alert" "worker" "$name" "match" "${match:0:200}"
            found=$((found + 1))
        fi
    done
    if [ "$found" -eq 0 ]; then
        echo "No alerts found."
    else
        echo "$found alert(s) detected."
    fi
}

cmd_stale() {
    # Check for workers with no new output in STALE_THRESHOLD_MIN minutes
    local threshold="${1:-$STALE_THRESHOLD_MIN}"
    local stale_count=0

    for name in $(list_workers); do
        local state
        state=$(read_worker_state "$name")
        local status
        status=$(echo "$state" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
        [ "$status" = "running" ] || continue

        local hash_file="$TEAM_STATE_DIR/${name}.hash"
        local output
        output=$(read_worker "$name" 2>/dev/null) || continue
        local current_hash
        current_hash=$(echo "$output" | md5 2>/dev/null || echo "$output" | md5sum 2>/dev/null | cut -d' ' -f1)

        if [ -f "$hash_file" ]; then
            local prev_hash
            prev_hash=$(cat "$hash_file")
            if [ "$current_hash" = "$prev_hash" ]; then
                local prev_time
                prev_time=$(stat -f %m "$hash_file" 2>/dev/null || stat -c %Y "$hash_file" 2>/dev/null || echo "0")
                local now
                now=$(date +%s)
                local age_min=$(( (now - prev_time) / 60 ))
                if [ "$age_min" -ge "$threshold" ]; then
                    echo "STALE [$name]: No new output for ${age_min}m (threshold: ${threshold}m)"
                    _emit_event "worker.stale" "worker" "$name" "idle_min" "$age_min"
                    stale_count=$((stale_count + 1))
                else
                    echo "  OK  [$name]: Output unchanged for ${age_min}m"
                fi
            else
                echo "$current_hash" > "$hash_file"
                echo "  OK  [$name]: Active (new output detected)"
            fi
        else
            echo "$current_hash" > "$hash_file"
            echo "  OK  [$name]: First check recorded"
        fi
    done
    if [ "$stale_count" -gt 0 ]; then
        echo "$stale_count stale worker(s)."
    else
        echo "All workers active."
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cmd_help() {
    echo "team.sh — Parallel Execution Runtime (surface: $SURFACE)"
    echo ""
    echo "Workers:"
    echo "  spawn <name> <cmd>          Spawn a named worker in a new pane"
    echo "  spawn-parallel <n> <cmd>    Spawn N workers with the same task"
    echo "  status                      Show all worker status"
    echo "  wait [name]                 Wait for worker(s) to complete"
    echo "  read <name>                 Capture worker pane output"
    echo "  kill <name>                 Kill a specific worker"
    echo "  shutdown                    Kill all workers"
    echo "  clean                       Clear worker state files"
    echo ""
    echo "Persistence:"
    echo "  loop '<cmd>' [--max-iter N] Run until verify passes (default: 5 iterations)"
    echo ""
    echo "Monitoring:"
    echo "  scan                        Scan workers for error keywords"
    echo "  stale [minutes]             Check for workers with no new output"
    echo ""
    echo "Info:"
    echo "  surface                     Show detected multiplexer"
    echo "  help                        This message"
    echo ""
    echo "Environment:"
    echo "  TEAM_SURFACE=tmux|cmux|auto   Force surface (default: auto)"
    echo "  TEAM_STATE_DIR=<path>         State directory"
    echo "  ALERT_KEYWORDS=<regex>        Keyword pattern for scan (default: error|FAIL|panic|...)"
    echo "  STALE_THRESHOLD_MIN=<N>       Stale detection threshold (default: 10)"
    echo "  MULTIAGENT_WEBHOOK_*=<url>    Webhook sinks (Slack, custom, etc.)"
}

case "${1:-help}" in
    spawn)          shift; cmd_spawn "$@" ;;
    spawn-parallel) shift; cmd_spawn_parallel "$@" ;;
    status)         cmd_status ;;
    wait)           shift; cmd_wait "${1:-all}" ;;
    read)           shift; cmd_read "$@" ;;
    kill)           shift; cmd_kill "$@" ;;
    shutdown)       cmd_shutdown ;;
    clean)          cmd_clean ;;
    loop)           shift; cmd_loop "$@" ;;
    scan)           cmd_scan ;;
    stale)          shift; cmd_stale "${1:-$STALE_THRESHOLD_MIN}" ;;
    surface)        cmd_surface ;;
    help|--help|-h) cmd_help ;;
    *)              echo "Unknown: $1. Run 'team.sh help'"; exit 1 ;;
esac
