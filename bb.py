#!/usr/bin/env python3
"""
bb.py — Blackboard CLI v2
==========================

Multi-agent Blackboard with:
  1. FIPA-ACL inspired structured communication protocol
  2. Filesystem-level verification (independent of agent self-reports)
  3. Time budgets with agent check-in protocol

Performatives (Speech Acts):
  INFORM      Agent reports a fact (test results, quality scores)
  REQUEST     Orchestrator asks an agent to perform a task
  PROPOSE     Architect proposes a design spec
  ACCEPT      Orchestrator accepts a proposal or result
  REJECT      Orchestrator rejects a result (triggers replan)
  PROHIBIT    Sentinel blocks the pipeline (absolute veto)
  CONFIRM     Independent verification confirms agent claim
  DISCONFIRM  Verification finds agent claim does not match reality
"""

import hashlib, json, os, subprocess, sys, time
from pathlib import Path

PERFORMATIVES = {
    "INFORM": "Agent reports a fact",
    "REQUEST": "Orchestrator requests work",
    "PROPOSE": "Agent proposes a plan (awaiting acceptance)",
    "ACCEPT": "Orchestrator accepts a proposal/result",
    "REJECT": "Orchestrator rejects a result",
    "PROHIBIT": "Sentinel blocks the pipeline (absolute veto)",
    "CONFIRM": "Verification confirms agent claim",
    "DISCONFIRM": "Verification contradicts agent claim",
}

AGENT_PERFORMATIVES = {
    "orchestrator": {"REQUEST", "ACCEPT", "REJECT"},
    "architect": {"INFORM", "PROPOSE"},
    "mason": {"INFORM"},
    "breaker": {"INFORM"},
    "shipp": {"INFORM"},
    "sentinel": {"INFORM", "PROHIBIT"},
    "wiki": {"INFORM"},
    "system": {"CONFIRM", "DISCONFIRM"},
}

WRITE_PERMISSIONS = {
    "task": {"orchestrator"}, "design_spec": {"architect"},
    "codebase_state": {"mason", "orchestrator"}, "test_results": {"breaker"},
    "quality_gate": {"shipp"}, "security_gate": {"sentinel"},
    "pipeline_status": {"orchestrator"}, "verification": {"system"},
}

def find_blackboard():
    current = Path.cwd()
    while current != current.parent:
        candidate = current / ".claude" / "blackboard.json"
        if candidate.exists() or (current / ".claude").is_dir():
            return candidate
        current = current.parent
    return Path.cwd() / ".claude" / "blackboard.json"

def load(path):
    if path.exists():
        try: return json.loads(path.read_text())
        except json.JSONDecodeError: return default_state()
    return default_state()

def save(path, state):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, indent=2, default=str))
    tmp.replace(path)

def default_state():
    return {
        "task": {}, "design_spec": {}, "codebase_state": {},
        "test_results": {}, "quality_gate": {}, "security_gate": {},
        "verification": {},
        "messages": [],
        "decisions_log": [],
        "pipeline_status": "idle",
        "budget": {
            "pipeline_deadline": None, "pipeline_max_minutes": None,
            "agent_limits": {"architect": 15, "mason": 30, "breaker": 15, "shipp": 10, "sentinel": 10, "wiki": 10},
            "agent_max_tool_calls": {"architect": 25, "mason": 50, "breaker": 30, "shipp": 15, "sentinel": 15, "wiki": 15},
            "checkins": [],
        },
        "file_snapshots": {},
        "meta": {"created_at": time.time(), "backend": "file"},
    }

def create_message(performative, sender, receiver, section, content, conversation_id=None):
    perf = performative.upper()
    if perf not in PERFORMATIVES:
        raise ValueError(f"Unknown performative: {perf}. Valid: {list(PERFORMATIVES.keys())}")
    allowed = AGENT_PERFORMATIVES.get(sender, set())
    if perf not in allowed:
        raise PermissionError(f"Agent '{sender}' cannot use '{perf}'. Allowed: {allowed}")
    section_writers = WRITE_PERMISSIONS.get(section, set())
    if sender != "system" and sender not in section_writers:
        raise PermissionError(f"Agent '{sender}' cannot write to '{section}'. Allowed: {section_writers}")
    return {"performative": perf, "sender": sender, "receiver": receiver,
            "section": section, "content": content,
            "conversation_id": conversation_id or f"pipeline-{int(time.time())}",
            "timestamp": time.time()}

def hash_file(filepath):
    p = Path(filepath)
    if not p.exists(): return None
    return hashlib.sha256(p.read_bytes()).hexdigest()

def snapshot_files(file_list):
    return {f: hash_file(f) for f in file_list}

# ---- Commands ----

def cmd_init(args):
    if not args:
        print("Usage: bb.py init 'task' [--tier 1|2|3] [--budget MINUTES]"); sys.exit(1)
    description, tier, budget_minutes = args[0], 1, None
    if "--tier" in args:
        idx = args.index("--tier")
        if idx + 1 < len(args): tier = int(args[idx + 1])
    if "--budget" in args:
        idx = args.index("--budget")
        if idx + 1 < len(args): budget_minutes = int(args[idx + 1])
    if budget_minutes is None:
        budget_minutes = {1: 15, 2: 45, 3: 90}.get(tier, 45)
    tier_agents = {1: ["mason"], 2: ["architect", "mason", "breaker", "shipp"],
                   3: ["architect", "mason", "breaker", "shipp", "sentinel", "wiki"]}
    tier_names = {1: "TRIVIAL", 2: "STANDARD", 3: "COMPLEX"}
    path = find_blackboard()
    if path.exists():
        archive_dir = path.parent / "blackboard_history"
        archive_dir.mkdir(exist_ok=True)
        path.rename(archive_dir / f"blackboard_{int(time.time())}.json")
        print(f"Archived previous state")
    now = time.time()
    state = default_state()
    state["task"] = {"description": description, "complexity_tier": tier,
                     "tier_name": tier_names.get(tier), "active_agents": tier_agents.get(tier, ["mason"]),
                     "fix_attempts": {}}
    state["pipeline_status"] = "running"
    state["budget"]["pipeline_max_minutes"] = budget_minutes
    state["budget"]["pipeline_deadline"] = now + (budget_minutes * 60)
    state["messages"] = [create_message("REQUEST", "orchestrator", tier_agents.get(tier, ["mason"])[0],
                                         "task", {"description": description, "tier": tier},
                                         conversation_id=f"pipeline-{int(now)}")]
    state["decisions_log"] = [{"agent": "orchestrator", "action": "classify",
                               "result": f"tier={tier_names.get(tier)}, agents={tier_agents.get(tier, [])}, budget={budget_minutes}m",
                               "timestamp": now}]
    # Auto-snapshot source files
    try:
        result = subprocess.run(["git", "ls-files"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            src_exts = {'.py','.js','.ts','.jsx','.tsx','.go','.rs','.java','.rb','.php','.c','.cpp','.h','.md','.yaml','.yml','.json','.toml'}
            git_files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
            source_files = [f for f in git_files if any(f.endswith(e) for e in src_exts)][:200]
            state["file_snapshots"] = snapshot_files(source_files)
            print(f"Snapshot: {len(state['file_snapshots'])} source files hashed")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        state["file_snapshots"] = {}
    save(path, state)
    print(f"Pipeline: {tier_names.get(tier)} (Tier {tier}) | Agents: {', '.join(tier_agents.get(tier, []))} | Budget: {budget_minutes}m")
    print(f"Task: {description[:80]}")

def cmd_msg(args):
    if len(args) < 5:
        print("Usage: bb.py msg <performative> <sender> <receiver> <section> '<json>'")
        print(f"Performatives: {', '.join(PERFORMATIVES.keys())}"); sys.exit(1)
    performative, sender, receiver, section = args[0], args[1], args[2], args[3]
    try: content = json.loads(args[4])
    except json.JSONDecodeError as e: print(f"Invalid JSON: {e}"); sys.exit(1)
    try: msg = create_message(performative, sender, receiver, section, content)
    except (ValueError, PermissionError) as e: print(f"Rejected: {e}"); sys.exit(1)
    path = find_blackboard()
    state = load(path)
    state.setdefault("messages", []).append(msg)
    current = state.get(section, {})
    if isinstance(current, dict) and isinstance(content, dict):
        current.update(content); state[section] = current
    else: state[section] = content
    save(path, state)
    print(f"[{performative}] {sender} -> {receiver} : {section}")

def cmd_verify(args):
    path = find_blackboard()
    state = load(path)
    cs = state.get("codebase_state", {})
    files_claimed = cs.get("files_modified", [])
    prior = state.get("file_snapshots", {})
    verification = {}
    print("=== Filesystem Verification ===\n")
    # 1. File modification claims
    if files_claimed:
        print("File modification claims:")
        for f in files_claimed:
            cur = hash_file(f)
            prev = prior.get(f)
            if cur is None:
                status = "MISSING"; print(f"  DISCONFIRM: {f} — does not exist")
            elif prev and cur == prev:
                status = "UNCHANGED"; print(f"  DISCONFIRM: {f} — hash unchanged")
            elif prev and cur != prev:
                status = "CONFIRMED"; print(f"  CONFIRM: {f} — changed")
            elif prev is None and cur:
                status = "NEW_FILE"; print(f"  CONFIRM: {f} — new file")
            else:
                status = "UNKNOWN"; print(f"  UNKNOWN: {f}")
            verification[f] = {"claimed": "modified", "status": status}
    else:
        print("No file claims to verify.")
    # 2. Git cross-reference
    print()
    try:
        result = subprocess.run(["git", "diff", "--name-only"], capture_output=True, text=True, timeout=10)
        if result.returncode == 0:
            git_changed = set(f.strip() for f in result.stdout.strip().split("\n") if f.strip())
            # Include untracked files
            result2 = subprocess.run(["git", "ls-files", "--others", "--exclude-standard"],
                                      capture_output=True, text=True, timeout=10)
            if result2.returncode == 0:
                git_changed |= set(f.strip() for f in result2.stdout.strip().split("\n") if f.strip())
            claimed_set = set(files_claimed)
            unclaimed = git_changed - claimed_set
            phantom = claimed_set - git_changed
            verification["git_cross_ref"] = {"unclaimed_changes": list(unclaimed), "phantom_claims": list(phantom)}
            print(f"Git: {len(git_changed)} changed file(s)")
            if unclaimed: print(f"  ⚠ Changed but NOT claimed: {unclaimed}")
            if phantom: print(f"  ⚠ Claimed but NOT in git: {phantom}")
            if not unclaimed and not phantom: print(f"  All claims match git.")
    except (subprocess.TimeoutExpired, FileNotFoundError):
        print("Git not available for cross-reference.")
    # 3. Test verification
    print()
    tr = state.get("test_results", {})
    if tr.get("total_tests"):
        print(f"Breaker claimed: {tr.get('passed')}/{tr.get('total_tests')} passed")
        for cmd_list, name in [
            (["python", "-m", "pytest", "--tb=no", "-q"], "pytest"),
            (["python", "-m", "unittest", "discover", "-q"], "unittest"),
            (["npm", "test", "--", "--silent"], "npm test"),
        ]:
            try:
                result = subprocess.run(cmd_list, capture_output=True, text=True, timeout=120)
                if result.returncode == 0:
                    print(f"  CONFIRM: {name} passes"); verification["tests"] = {"status": "CONFIRMED"}
                else:
                    print(f"  DISCONFIRM: {name} fails (exit {result.returncode})")
                    verification["tests"] = {"status": "DISCONFIRMED", "output": result.stdout[-300:]}
                break
            except (subprocess.TimeoutExpired, FileNotFoundError): continue
    else:
        print("No test claims to verify.")
    # Write verification
    has_issues = any(isinstance(v, dict) and v.get("status") in ("DISCONFIRM", "UNCHANGED", "MISSING", "DISCONFIRMED")
                     for v in verification.values())
    perf = "DISCONFIRM" if has_issues else "CONFIRM"
    state["verification"] = verification
    state.setdefault("messages", []).append(
        create_message(perf, "system", "orchestrator", "verification", verification))
    save(path, state)
    print(f"\n[{perf}] Verification results written to Blackboard.")

def cmd_snapshot(args):
    path = find_blackboard()
    state = load(path)
    if args and args[0] == "--git":
        try:
            result = subprocess.run(["git", "ls-files"], capture_output=True, text=True, timeout=10)
            files = [f.strip() for f in result.stdout.strip().split("\n") if f.strip()]
        except: print("Git not available."); sys.exit(1)
    elif args:
        files = args
    else:
        files = state.get("codebase_state", {}).get("files_modified", [])
        if not files: print("No files specified. Usage: bb.py snapshot file1.py file2.py"); sys.exit(1)
    snaps = snapshot_files(files)
    state["file_snapshots"] = {**state.get("file_snapshots", {}), **snaps}
    save(path, state)
    print(f"Snapshot: {sum(1 for v in snaps.values() if v is not None)}/{len(files)} files hashed")

def cmd_show(args):
    path = find_blackboard()
    state = load(path)
    if args:
        section = args[0]
        if section == "messages":
            for m in state.get("messages", []):
                print(f"[{m.get('performative','?'):11s}] {m.get('sender','?'):12s} -> {m.get('receiver','?'):12s} : {m.get('section','?')}")
        elif section == "decisions_log":
            for e in state.get("decisions_log", []):
                print(f"[{e.get('agent','?'):12s}] {e.get('action','?'):20s} -> {e.get('result','?')}")
        elif section in state:
            print(json.dumps(state[section], indent=2, default=str))
        else:
            print(f"Unknown: {section}. Available: {', '.join(state.keys())}"); sys.exit(1)
    else:
        task = state.get("task", {})
        cs = state.get("codebase_state", {})
        tr = state.get("test_results", {})
        qg = state.get("quality_gate", {})
        sg = state.get("security_gate", {})
        msgs = state.get("messages", [])
        verif = state.get("verification", {})
        print(f"Pipeline: {state.get('pipeline_status', '?')}")
        print(f"Task: {task.get('description', 'none')[:60]}")
        print(f"Tier: {task.get('tier_name', '?')} | Agents: {', '.join(task.get('active_agents', []))}")
        files = cs.get("files_modified", [])
        if files: print(f"Files: {', '.join(files)} (+{cs.get('lines_added',0)} -{cs.get('lines_removed',0)})")
        total = tr.get("total_tests", 0)
        if total: print(f"Tests: {tr.get('passed',0)}/{total} passed")
        if qg.get("status","pending") != "pending": print(f"Quality: {qg['status']} (lint: {qg.get('lint_score','?')})")
        if sg.get("status","pending") != "pending": print(f"Security: {'BLOCKED' if sg['status']=='block' else 'pass'}")
        if verif:
            issues = sum(1 for v in verif.values() if isinstance(v,dict) and v.get("status") in ("DISCONFIRM","UNCHANGED","MISSING","DISCONFIRMED"))
            print(f"Verification: {'⚠ '+str(issues)+' issue(s)' if issues else 'all confirmed'}")
        print(f"\nMessages: {len(msgs)}")
        perf_counts = {}
        for m in msgs: perf_counts[m.get("performative","?")] = perf_counts.get(m.get("performative","?"),0) + 1
        if perf_counts: print(f"  {', '.join(f'{k}={v}' for k,v in sorted(perf_counts.items()))}")
        if msgs:
            print(f"  Latest:")
            for m in msgs[-3:]:
                print(f"    [{m.get('performative','?'):11s}] {m.get('sender','?')} -> {m.get('receiver','?')} : {m.get('section','?')}")

def cmd_update(args):
    if len(args) < 2: print("Usage: bb.py update <section> '<json>'"); sys.exit(1)
    section = args[0]
    try: data = json.loads(args[1])
    except json.JSONDecodeError as e: print(f"Invalid JSON: {e}"); sys.exit(1)
    agent_map = {"task":"orchestrator","design_spec":"architect","codebase_state":"mason",
                 "test_results":"breaker","quality_gate":"shipp","security_gate":"sentinel"}
    sender = agent_map.get(section, "orchestrator")
    if section == "security_gate" and data.get("status") == "block": perf = "PROHIBIT"
    elif section == "design_spec": perf = "PROPOSE"
    else: perf = "INFORM"
    path = find_blackboard()
    state = load(path)
    try: msg = create_message(perf, sender, "orchestrator", section, data)
    except (ValueError, PermissionError) as e: print(f"Rejected: {e}"); sys.exit(1)
    state.setdefault("messages", []).append(msg)
    current = state.get(section, {})
    if isinstance(current, dict) and isinstance(data, dict): current.update(data); state[section] = current
    else: state[section] = data
    save(path, state)
    print(f"[{perf}] {sender} -> orchestrator : {section}")

def cmd_log(args):
    if len(args) < 3: print("Usage: bb.py log <agent> <action> 'result'"); sys.exit(1)
    path = find_blackboard()
    state = load(path)
    state.setdefault("decisions_log", []).append(
        {"agent": args[0], "action": args[1], "result": args[2], "timestamp": time.time()})
    save(path, state)
    print(f"Logged: [{args[0]}] {args[1]} -> {args[2]}")

def cmd_reset(args):
    path = find_blackboard()
    if path.exists():
        archive_dir = path.parent / "blackboard_history"; archive_dir.mkdir(exist_ok=True)
        path.rename(archive_dir / f"blackboard_{int(time.time())}.json"); print("Archived.")
    save(path, default_state()); print("Blackboard reset.")

def cmd_failures(args):
    state = load(find_blackboard())
    failures = state.get("test_results", {}).get("failures", [])
    blocking = [f for f in failures if f.get("severity") in ("critical", "high")]
    if not blocking: print("No blocking failures."); return
    print(f"{len(blocking)} blocking failure(s):\n")
    for f in blocking:
        for k in ["test_name","file","line","expected","actual","reproduction","severity"]:
            label = k.upper().replace("_"," ")
            print(f"{label}: {f.get(k, '?')}")
        print("---")

def cmd_fix_attempt(args):
    if not args: print("Usage: bb.py fix-attempt <module>"); sys.exit(1)
    path = find_blackboard()
    state = load(path)
    attempts = state.setdefault("task", {}).setdefault("fix_attempts", {})
    attempts[args[0]] = attempts.get(args[0], 0) + 1
    count = attempts[args[0]]
    save(path, state)
    if count >= 3: print(f"FIX ATTEMPT {count} for {args[0]} — THRESHOLD EXCEEDED\n-> MAJORITY VOTING")
    elif count == 2: print(f"FIX ATTEMPT {count} for {args[0]} — WARNING: next triggers majority voting")
    else: print(f"FIX ATTEMPT {count} for {args[0]}")

def cmd_checkin(args):
    if not args: print("Usage: bb.py checkin <agent> [msg]"); sys.exit(1)
    agent, message = args[0], args[1] if len(args) > 1 else "working"
    path = find_blackboard()
    state = load(path)
    now = time.time()
    budget = state.get("budget", {})
    checkins = budget.setdefault("checkins", [])
    checkins.append({"agent": agent, "message": message, "timestamp": now})
    deadline = budget.get("pipeline_deadline")
    if deadline and now > deadline:
        state["pipeline_status"] = "timeout"; save(path, state)
        print(f"STOP — Pipeline deadline exceeded"); sys.exit(2)
    agent_max = budget.get("agent_limits", {}).get(agent)
    if agent_max:
        ac = [c for c in checkins if c["agent"] == agent]
        if len(ac) > 1 and (now - ac[0]["timestamp"]) / 60 > agent_max:
            save(path, state)
            print(f"STOP — {agent} exceeded {agent_max}m limit"); sys.exit(2)
    save(path, state)
    rem_p = max(0, (deadline - now) / 60) if deadline else None
    rem_a = None
    if agent_max:
        ac = [c for c in checkins if c["agent"] == agent]
        if ac: rem_a = max(0, agent_max - (now - ac[0]["timestamp"]) / 60)
    candidates = [r for r in [rem_p, rem_a] if r is not None]
    rem = min(candidates) if candidates else None
    if rem is not None:
        if rem < 5: print(f"CONTINUE — ⚠ {rem:.0f}m remaining")
        else: print(f"CONTINUE — {rem:.0f}m remaining")
    else: print("CONTINUE")

def cmd_budget(args):
    path = find_blackboard()
    state = load(path)
    budget = state.get("budget", {})
    now = time.time()
    if not args:
        deadline = budget.get("pipeline_deadline")
        print("=== Budget Status ===")
        print(f"Elapsed: {(now - state.get('meta',{}).get('created_at', now)) / 60:.1f}m")
        if deadline:
            rem = max(0, (deadline - now) / 60)
            print(f"Pipeline: {rem:.0f}m remaining of {budget.get('pipeline_max_minutes')}m [{'ON TRACK' if rem > 10 else '⚠ LOW' if rem > 0 else 'EXCEEDED'}]")
        print(f"\nAgent limits:")
        for a, lim in sorted(budget.get("agent_limits", {}).items()):
            ac = [c for c in budget.get("checkins", []) if c["agent"] == a]
            if ac:
                used = (now - ac[0]["timestamp"]) / 60
                print(f"  {a:10s}: {lim:3d}m limit, {used:.1f}m used, {max(0,lim-used):.0f}m left")
            else: print(f"  {a:10s}: {lim:3d}m limit (idle)")
        msgs = state.get("messages", [])
        perf_counts = {}
        for m in msgs: perf_counts[m.get("performative","?")] = perf_counts.get(m.get("performative","?"),0) + 1
        print(f"\nProtocol: {len(msgs)} messages")
        if perf_counts: print(f"  {', '.join(f'{k}={v}' for k,v in sorted(perf_counts.items()))}")
        return
    subcmd = args[0]
    if subcmd == "set-pipeline" and len(args) >= 2:
        m = int(args[1]); budget["pipeline_max_minutes"] = m; budget["pipeline_deadline"] = now + m*60
        state["budget"] = budget; save(path, state); print(f"Pipeline: {m}m")
    elif subcmd == "set-agent" and len(args) >= 3:
        budget.setdefault("agent_limits",{})[args[1]] = int(args[2])
        state["budget"] = budget; save(path, state); print(f"{args[1]}: {args[2]}m")
    elif subcmd == "set-tools" and len(args) >= 3:
        budget.setdefault("agent_max_tool_calls",{})[args[1]] = int(args[2])
        state["budget"] = budget; save(path, state); print(f"{args[1]}: {args[2]} max calls")
    else: print(f"Unknown: {subcmd}"); sys.exit(1)

COMMANDS = {"init": cmd_init, "show": cmd_show, "msg": cmd_msg, "update": cmd_update,
            "verify": cmd_verify, "snapshot": cmd_snapshot, "log": cmd_log, "reset": cmd_reset,
            "failures": cmd_failures, "fix-attempt": cmd_fix_attempt, "checkin": cmd_checkin,
            "budget": cmd_budget}

def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print("bb.py v2 — Structured Protocol + Filesystem Verification\n")
        print("Protocol:    msg <perf> <from> <to> <section> JSON")
        print(f"             Performatives: {', '.join(PERFORMATIVES.keys())}")
        print("Verify:      verify | snapshot [files|--git]")
        print("Pipeline:    init | show [section] | update | log | reset")
        print("Budget:      checkin | budget | failures | fix-attempt")
        sys.exit(0)
    cmd = sys.argv[1]
    if cmd not in COMMANDS: print(f"Unknown: {cmd}. Available: {', '.join(COMMANDS.keys())}"); sys.exit(1)
    COMMANDS[cmd](sys.argv[2:])

if __name__ == "__main__":
    main()
