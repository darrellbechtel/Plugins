# Multi-Agent Engineering Team — Research-Informed Architecture

## Design Philosophy

This architecture is grounded in Wooldridge's BDI model and Contract Net Protocol,
updated with empirical findings from 2024–2026 multi-agent LLM research. Three
key corrections from the literature drive the redesign:

1. **The Debate Martingale** (NeurIPS 2025): Open-ended agent debate does not
   improve expected correctness. Value comes from independent generation +
   targeted interventions, not philosophical back-and-forth.

2. **Sparse Communication** (Li et al. 2024, Zeng et al. 2025): Full connectivity
   between agents wastes 41–94% of tokens. Agents should receive only actionable,
   compressed signals from peers.

3. **Adaptive Activation** (survey evidence): Always-on full-team coordination
   burns tokens without proportional benefit. A complexity classifier should
   route simple tasks to minimal agent sets.

Additionally, Wooldridge's own 2025 critique ("LLMs Miss the Multi-Agent Mark")
demands a **structured environment layer** — a shared blackboard that exists
independently of natural language message-passing.

---

## System Components

```
┌─────────────────────────────────────────────────────┐
│                   BLACKBOARD                         │
│  (Structured shared state — not natural language)    │
│                                                      │
│  codebase_state: { files_modified, dependencies }    │
│  test_results:   { pass/fail, failing_lines, logs }  │
│  quality_gate:   { lint_score, coverage_pct }        │
│  task_context:   { complexity_tier, active_agents }  │
│  decisions_log:  [ { agent, action, timestamp } ]    │
└────────────────────────┬────────────────────────────┘
                         │
              ┌──────────┴──────────┐
              │    ORCHESTRATOR     │
              │   (BDI + Router)    │
              └──────────┬──────────┘
                         │
         ┌───────────────┼───────────────┐
         │               │               │
    ┌────┴────┐    ┌─────┴─────┐   ┌─────┴─────┐
    │  TIER 1 │    │  TIER 2   │   │  TIER 3   │
    │ Mason  │    │ + Breaker │   │ + Sentinel│
    │  only   │    │ + Shipp   │   │ + Wiki    │
    └─────────┘    └───────────┘   └───────────┘
```

---

## Complexity Tiers (Adaptive Activation)

The orchestrator classifies every incoming task before dispatching.

| Tier | Criteria | Active Agents | Examples |
|------|----------|---------------|----------|
| **1 — Trivial** | Single file, <50 LOC, no new deps | Mason | Fix typo, add log line, rename variable |
| **2 — Standard** | Multi-file OR new logic OR tests needed | Mason + Breaker + Shipp | New endpoint, refactor module, add feature |
| **3 — Complex** | Cross-cutting, security-sensitive, public API change | Full team | Auth system, DB migration, API redesign |

**Classification signals:**
- File count touched (estimated from task description)
- Presence of keywords: "security", "auth", "migration", "API", "breaking change"
- Whether task references existing test failures
- User-specified urgency or review requirements

---

## Communication Topology (Sparse by Default)

**Principle:** No agent receives another agent's full reasoning. They receive
only structured, compressed signals via the blackboard.

### What each agent READS from the blackboard:

| Agent | Reads |
|-------|-------|
| **Mason** | `task_context`, `codebase_state`, `test_results.failing_lines` |
| **Breaker** | `codebase_state.files_modified`, `test_results` |
| **Shipp** | `quality_gate.pass_fail`, `test_results.summary` |
| **Sentinel** | `codebase_state`, `quality_gate`, `decisions_log` |
| **Wiki** | `codebase_state.files_modified`, `decisions_log` |

### What each agent WRITES to the blackboard:

| Agent | Writes |
|-------|--------|
| **Mason** | `codebase_state`, code files |
| **Breaker** | `test_results` (structured: pass/fail + specific failing lines + reproduction steps) |
| **Shipp** | `quality_gate` (lint, format, build status) |
| **Sentinel** | `quality_gate.security_findings`, approval/block decision |
| **Wiki** | Documentation files, `decisions_log` annotations |

### What agents NEVER see:

- Mason never sees Sentinel's full security analysis reasoning
- Breaker never sees Mason's implementation rationale
- Shipp never sees Breaker's test logic
- Wiki never sees raw test output

This enforces the sparse topology finding: agents operate on compressed,
actionable signals rather than full conversational context.

---

## Conflict Resolution Protocol

Based on Wooldridge's argumentation frameworks, adapted for the martingale finding.

**Key insight:** Don't let agents debate. Instead, use a priority ordering with
structured escalation.

### Priority Ordering (Orchestrator-Enforced):

1. **Sentinel security block** → Absolute veto. Mason must fix before proceeding.
2. **Breaker test failure** → Mason must address specific failing cases.
   Breaker provides reproduction, not opinions.
3. **Shipp quality gate failure** → Mason addresses if below threshold.
4. **Conflicting approaches** → Orchestrator requests N independent implementations
   from Mason, selects based on test pass rate (majority voting > debate).

### Escalation Triggers:

- Mason fails to resolve Breaker's findings after 2 attempts → Orchestrator
  replans the approach (intention reconsideration per BDI)
- Sentinel blocks 3+ times on same pattern → Flag for human review
- Quality gate stuck below threshold → Orchestrator decomposes into smaller subtasks

---

## Intention Reconsideration Policy (BDI)

From Wooldridge's BDI model — the most critical tuning parameter.

**Default:** Commit to plan. Do not reconsider unless:

| Trigger | Action |
|---------|--------|
| Breaker reports 3+ failing test cases in same module | Orchestrator replans approach |
| Mason's implementation exceeds 2x estimated LOC | Pause and reassess scope |
| New information from codebase scan contradicts assumptions | Full replan |
| Time budget exceeded by 50% | Ship partial + document remaining |

**Anti-pattern to avoid:** Reconsidering after every Breaker cycle. The empirical
evidence shows this degrades output quality (martingale effect — iterative
critique converges to noise, not truth).
