# BRS/DRS background learning for newbee

Status: reviewed proposal v2; not implemented. The [Chinese design](brs-drs-design.zh-CN.md) is the maintained primary document. This companion records the same implementation decisions and contracts.

## 1. Product objective

BRS explores a small set of different relevant questions to discover coverage gaps. DRS investigates a specific observed failure, practices a proposed remedy, and checks transfer on tasks not used during practice. Model weights remain fixed; scoped experience changes.

The first deliverable is an auditable offline DRS experiment: practice evidence, candidate lessons, and a frozen baseline/candidate comparison. It does not activate production releases, generate executable tools, or run BRS in parallel. Repeated attempts eventually succeeding do not by themselves establish learning.

## 2. Review corrections

| Initial problem | v2 decision |
| --- | --- |
| Frozen evaluation deferred until phase three | Include it in the first DRS experiment |
| Existing Explorer and Verifier capabilities overstated | Explicit adaptation and isolation prerequisites |
| Execution, correctness, and admission mixed together | Three separate state fields |
| Immutable baseline confused with evolving memory | Fixed starting baseline plus advancing learning_head |
| Coordinator ownership unspecified | Environment Coordinator owns learning facts; Hive owns execution tasks |
| Worktrees described as sufficient isolation | Enforce and test OS and Host access boundaries |
| Idempotency without crash semantics | Durable commit point, receipts, replay, and reconciliation |

All requirements below are proposed behavior, not claims about current implementation.

## 3. Source baseline and gaps

Reviewed checkout: `211d5126fd6fc3182b16acfd274fa181694c3145`. Uncommitted changes in the main workspace are outside this review.

| Source | Existing behavior | Missing guarantee |
| --- | --- | --- |
| [Adapter](../lib/newbee/agent/adapter.ex) | Signal-to-proposal synthesis | Practice lineage and memory advancement |
| [Explorer](../lib/newbee/agent/explorer.ex) | Separate Loop/evaluator and worktree | Execution ignores `_opts`, marks results done, maps model done to accepted, removes worktree before returning; unsuitable for direct learning admission |
| [Verification](../lib/newbee/collaboration/verification.ex) | Commands, file existence, SHA-256, contract-bound attestations | Not a code sandbox or general semantic/visual verifier |
| [Submission](../lib/newbee/collaboration/submission.ex) | Task-bound source snapshot and hash validation | Not a snapshot of processes, databases, or remote services |
| [Release Verifier](../lib/newbee/environment/verifier.ex) | Static/self-test/antibody and projection checks | Counterfactual path reports `proves: projection_compatibility`, not task improvement; self-test isolation must also be verified |
| [Memory](../lib/newbee/memory.ex) | Global topic text, redaction, TTL | No experimental version/admission/freeze contract |
| [Environment Coordinator](../lib/newbee/environment/coordinator.ex) | Change/Revision/evaluation/activation | New learning commands and reducer required |
| [Collaboration Coordinator](../lib/newbee/collaboration/coordinator.ex) | Hive task/submission/delivery lifecycle | Must not become a second memory/release authority |

Evaluator crash isolation and worktree write separation are useful but do not enforce all filesystem read or external-effect boundaries.

## 4. Scope and ownership

MVP profile: offline Elixir tool-use and error-recovery fixtures, with fixed inputs, dependencies, initial files, and deterministic acceptance. No real business services, credentials, or live provider failure learning.

Curriculum is an Adapter planning responsibility, not a new permanent model identity. Worker supplies evidence references and continues user work; a signal is not permission to execute background work.

`Newbee.Environment.Coordinator` owns lineage state, budget reservations, admission, and learning_head. A proposed pure reducer holds contracts. Supervised tasks perform long work outside GenServer callbacks.

`Newbee.Collaboration.Coordinator` and Hive retain task dispatch, attempt identity, submission, and acceptance. Lineages reference these IDs instead of copying Board or delivery state. Use Hive isolated execution, not the legacy `Agent.Explorer.run/2` directly; reusable Loop/evaluator components need budget, evidence retention, and isolation adaptations first.

Adapter proposes scoped text lessons only in MVP. It cannot alter checks or publish executable rules/tools. Trusted deterministic verification judges outcomes. Future semantic verification gets a separate context with actual access restrictions. Host enforces resources and effects. Production activation still requires Change/Verifier/Autonomy.

## 5. Version identities

| Identity | Meaning | Mutation rule |
| --- | --- | --- |
| baseline_id | Source/dependencies/tools/configuration and starting memory M0 | Immutable; changed source/model/policy starts a new lineage |
| learning_head | Memory Mn admitted for subsequent practice | Advances only through admission events |
| input_memory_id | Exact memory of one attempt | Fixed at dispatch |
| wave_input_memory_id | Shared BRS input | Fixed within wave; next wave may use its committed successor |
| evaluation_snapshot_id | Complete evaluated input | Immutable; changed configuration invalidates comparison |

Reset files and interaction state for each DRS attempt, inheriting only admitted memory. Production may evolve independently; experiments remain pinned. A stale production base requires reevaluation before promotion.

Experimental memory is an immutable Evaluation Evidence artifact in the existing project Store, not a new database and not a write to global `Memory.write`. Each manifest identifies parent, ordered experience IDs, entry hashes, and provenance. Publication remains a separate Change.

## 6. DRS protocol

1. Register a manually selected failure and validate scope, fixture, oracle, and budget. Missing prerequisites block execution.
2. Reproduce the development target under M0. Record `not_reproduced` if reproduction fails; do not infer a repair.
3. Adapter proposes one falsifiable hypothesis and practice. Host locks its acceptance before Actor execution.
4. A clean branch reads Mn. Actor done means ready to submit, not correct.
5. Seal output and run trusted checks in a separate check workspace. Classify behavioral failure as fail, infrastructure/checker failure as infra_error, insufficient evidence as unknown.
6. Actor may supply evidence-referenced lessons; Adapter consolidates without requiring private reasoning. Passing an instance is not a universal rule.
7. Require scope, preconditions, evidence and a contrast/boundary example for positive or negative admission. Otherwise retain candidate evidence without moving learning_head.
8. After memory changes, retry the unchanged development target in a clean environment. Target completion requires a verifier result.
9. Stop learning and freeze Mn for the precommitted held-out comparison.

Curriculum `ready` means ready for checking; verifier produces `target_pass`. A bounded follow-up may challenge a fragile PASS, but any memory change requires another target verification.

## 7. BRS protocol (later)

Freeze task batch, authored order, checks, and budget before observing branch scores. All branches use the same source and wave memory. They submit and verify independently; a trusted fail is a valid semantic outcome.

At the complete-wave barrier, unknown/infra_error/missing evidence blocks publication. Apply the fixed retry limit, then abort or quarantine the wave if unresolved. Consolidate admissible positive and negative lessons in authored order. Conflicts remain unresolved and excluded from actionable guidance; majority vote is not a truth oracle.

Publish a single complete Mn+1, or record no_change if nothing is admissible. An aborted wave retains evidence and publishes no subset. Head-of-line blocking is an explicit initial tradeoff; partial publication would require a predeclared unit and reporting policy, not post-hoc removal of bad results.

## 8. State and record contracts

| Field | Values | Authority |
| --- | --- | --- |
| execution_status | queued / running / submitted / terminal | Runner and Host |
| execution_reason | completed / infra_error / cancelled / budget_exhausted | Host |
| verdict | pending / pass / fail / unknown | Verifier; infra_error stays unknown |
| admission | not_proposed / candidate / admitted / rejected / quarantined | Environment Coordinator with validated receipt |

`terminal + completed + fail + admitted` can represent a verified negative lesson. `terminal + infra_error + unknown + quarantined` cannot advance memory.

Lineage lifecycle: `created -> planned -> practicing -> learning_stopped -> evaluating -> closed`. Blocked work resumes only from validated receipts; cancellation is explicit. Learning stop reasons: target_pass, saturated, budget_exhausted, stalled, infra_error. Closed is not success; evaluation conclusion is improved, regressed, no_clear_gain, or invalid.

Proposed schema_version=1 records:

- Baseline: id, project_id, source_tree_hash, dependencies_hash, release_map, M0, model_config_hash, policy_hash, fixture_version.
- Lineage: id, baseline_id, trigger_event_ids, phase, learning_head, state, stop_reason, budget_reserved/spent, event_revision.
- Attempt: id, lineage_id, wave_id, parent_attempt_id, Hive task_id/attempt, input_memory_id, contract_hash, submission_id/hash, execution/verdict/admission, cost, dispatch_id.
- Experience: id, attempt_id, claim, scope, preconditions, counterexamples, uncertainties, source_event_ids, artifact_hashes, verifier_receipt, admission.
- Memory manifest: id, parent_id, ordered_experience_ids, entry_hashes, manifest_hash, schema_version.
- Evaluation: id, baseline/candidate snapshots, locked_cohort_hash, judge_version, model/provider_config, budget, trials, all_outcomes, cost, conclusion.

Validate both writes and reads. Model proposals cannot forge admission, trusted IDs, hashes, or verifier results.

## 9. Execution and evidence boundaries

Before automatic practice runs, provide and test an OS process/container or equivalent sandbox with restricted read/write roots, stripped credentials, and disabled external networking. Model APIs run through controlled Host transport.

Deny access to production `.newbee`, other sessions, global memory, sibling branches, hidden checks, and evaluation reports. Mount input_memory read-only. Host bridges must also validate experiment identity, allowed roots, and operation classes; the bridge cannot bypass the OS boundary.

Checks use a pinned trusted version and separate workspace. Temporary test output is allowed outside immutable candidate content; validate candidate hashes before and after checking. Bind receipts to attempt, candidate, contract, and checker version. Actor cannot modify acceptance code. Hidden evaluation oracles stay outside Actor access.

File existence/hashes prove artifact identity; fixture behavior assertions establish correctness. Empty contracts, self-tests, model done, and projection compatibility do not establish learning gains.

MVP excludes general semantic verification and whole-VM rollback. Remote services require a separate effect/snapshot policy; environment rollback cannot undo a sent request.

Infrastructure errors do not teach business correctness, but remain maintenance evidence. Learning infrastructure recovery itself requires a new fault-injection fixture with a recovery-specific oracle.

## 10. Durable commit and recovery

Use existing EventStore facts and content-addressed project Store artifacts. Register new events as durable; acknowledgment must precede state advancement.

1. Stage artifacts, validate hashes/references, durably persist, atomically rename to immutable objects.
2. Environment Coordinator checks expected_learning_head, expected_event_revision, attempt, receipts, and admission conditions.
3. Append durable memory_committed with command_id, old/new memory, and ordered experience IDs. This event is the sole commit point; update projections after acknowledgment.
4. Crash before event leaves unreferenced artifacts and unchanged head. Crash after event replays the same commit without another model consolidation.

Same command_id and payload returns the original result; same ID with different payload is rejected. Stale heads/attempts are rejected. Persist completed consolidation responses for recovery.

No cross-Coordinator transaction is claimed. Stable references, consumption watermarks, and reconciliation connect Hive submissions to learning events. Duplicate delivery cannot duplicate admission; lost acknowledgment queries the original result.

A Host crash after a model call can leave unknown billing/outcome. Record ambiguous_call, conservatively retain budget reservation, and reconcile. Without provider idempotency, neither exactly-once calls nor exactly-once charges are promised. A retry is a new reasoned attempt.

Missing artifacts, hash mismatches, or checker mismatch quarantine work. Seal before workspace cleanup. GC only removes unreferenced artifacts after retention; preserve active and review-pending evidence.

## 11. Frozen comparison from MVP

Before learning, lock development targets, practice scope, and held-out tasks. Never select tasks based on evaluation scores. Original-target-only retry demonstrates target repair, not transfer.

Control uses M0; candidate uses Mn. Fix source, dependencies, tools, model/provider configuration, judge, task cohort, per-task call/token limits, and initial state. Only memory differs. Reset each trial and interleave arm order to reduce service drift. Record seeds when supported without promising deterministic LLM replay.

Pilot suggestion: 10 held-out fixtures and 3 trials per task per arm. These are configurable feasibility numbers, not statistical sufficiency. Reserve evaluation cost before learning; insufficient budget means reducing the predeclared study or stopping, never selecting best runs afterward.

Show every planned outcome: pass, fail, unknown, infra_error, cancelled, missing. Report semantic score and coverage separately. Do not turn infrastructure errors into automatic task zeros or silently remove them. Retry policy is symmetric; retain every attempt, not the highest score.

Report paired task outcomes, regressions, intervals/sample limits, all learning/checking cost, and expected future reuse. Small or ambiguous improvements yield no_clear_gain, not automatic release approval.

Frozen runs carry learning_enabled=false. Adapter collectors, memory writes, and automatic antibody paths must enforce it, not merely log it. If evaluation feedback later guides a new candidate, that cohort becomes development data and a new held-out cohort is required.

## 12. Budget and stopping

MVP: manual start, one lineage, serial execution, at most 3 new practices, at most 1 infrastructure retry per practice, no recursive delegation. Later BRS default: 3 branches, concurrency 2. Defaults must be configurable, persisted, and labeled uncalibrated.

Require total calls, tokens, wall time, disk, and evaluation reserve at admission. Include planning, Actor, checking, distillation, consolidation, retries, and both evaluation arms. Reserve before dispatch and reconcile afterward. Mark estimated/unknown usage honestly.

Do not start practice that consumes evaluation reserve. Host hard time/cost limits may interrupt a wave; record evidence and do not publish partial memory. Boundary-only semantic stopping does not override resource enforcement.

Daemon/need/TCE integration follows MVP, with deduplication, foreground priority, bounded scheduling, and pause controls. Repeated errors cannot create unlimited experiments. TCE prioritization does not substitute for measured outcome improvement.

## 13. Rollout and acceptance

| Stage | Deliverable | Exit condition |
| --- | --- | --- |
| A | Contracts/reducer, fixture, OS/Host boundary, budgets, sealing/recovery | Mock-model and fault-injection tests; no paid practice |
| B | Offline DRS plus frozen comparison | One real-model pilot with all outcomes; no activation |
| C | Reviewed candidate publication and background scheduling | Outcome evidence, required regressions, stale-base reevaluation, existing Autonomy |
| D | BRS waves | Equal-budget DRS-only/BRS-only/combined comparison; no default enablement without evidence |

Implement and verify these invariants during their respective stages:

1. Model done with a failed assertion remains fail and cannot admit a positive lesson.
2. Verified negative lessons can be admitted without changing task fail to pass.
3. Unknown does not advance head and budget exhaustion never upgrades it.
4. OS/Host reject production memory, credential, sibling, and hidden-oracle reads.
5. Candidate/checker modification is refused or invalidates verification.
6. Crashes before and after the durable event restore zero or one commit respectively.
7. Duplicate command/delivery and late attempts cannot duplicate admission; conflicting payloads are rejected.
8. Mn+1 affects only subsequent attempts, not current attempts or sibling branches.
9. BRS infra_error blocks publication; valid fail can teach; conflicts are not actionable.
10. Frozen errors remain logged without Adapter/antibody/memory learning.
11. Production evolution does not change pinned experiments; stale promotion rechecks.
12. All role and retry costs count; unknown billing is not treated as free.
13. Fixed-output replay proves mechanics only; capability claims require real execution comparison.
14. Reports retain missing results, failures, retries, and costs without filling unrun candidate tasks with historical baselines.

Stage B excludes automatic activation, global memory publication, GUI evaluation, and arbitrary third-party projects.

## 14. Sources and remaining decisions

Sources: [RSIAgent architecture](https://github.com/AetherLabsAI/RSIAgent/blob/main/docs/ARCHITECTURE.md), [reporting scope](https://github.com/AetherLabsAI/RSIAgent/blob/main/docs/PAPER.md), [paper](https://arxiv.org/abs/2609.15364). Its retained baselines, selected retries, and differing budgets do not guarantee newbee improvements.

Fixed decisions: offline Elixir fixtures, text lessons, Environment Coordinator ownership, Hive execution, frozen comparison from MVP, manual start, no activation.

Stage A must choose and verify an OS backend compatible with the Host bridge, select fixtures and held-out cohort, measure resource limits, and choose reporting statistics. Existing module names are not evidence that these prerequisites are implemented.

Continue investment only if a pilot supports fewer errors on unseen tasks under equal execution budgets, with learning costs plausibly recoverable through reuse. Otherwise preserve evidence, narrow the problem, or stop.