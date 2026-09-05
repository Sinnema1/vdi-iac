# ADR 8: bounded local orchestration experiment

## Status

Proposed implementation for review; no remote publication or lab execution.

## Context

The repository contains shell and PowerShell validation, not a hosted service
or existing durable workflow engine. Slice 001 tests orchestration with a
synthetic scanner regression without changing the image lifecycle contracts.
Introducing Temporal here would add a service, SDK and operations requirements
to a workload that intentionally stops at a local human review packet.

## Decision

Use a temporary single-host SQLite driver in `experiments/slice001`. Persist
Task intent independently of TaskExecution attempts. Pin repository input and
use fresh worktrees, a fixed validation policy, hashed artifacts and bounded
attempts. Reject concurrent drivers with an operating-system lock. An uncertain
attempt is abandoned and counted, never replayed in place. Human approval binds
the exact successful evidence packet. The driver has no publishing capability.

The replacement boundary is `LocalRunner`: create, attempt, recover, report and
approve expose domain semantics independent of an engine. Its worktree/patch/
validation activity consumes the pinned Task and emits an execution result and
artifacts. A Temporal adapter should schedule that activity, keep these Task and
TaskExecution meanings and IDs, receive approval as a signal, and use execution
IDs as idempotency keys. Engine activity retries must not silently create or
repeat engineering attempts outside the domain budget.

## Consequences

This is deliberately not a general durable workflow engine. There are no
persisted timers, queues, leases or automatic scheduling. SQLite supplies local
transaction semantics; operator-triggered recovery supplies the minimal pilot
recovery policy. Temporal adoption is required before adding distributed
workers, durable timed waits or unattended scheduling. The adapter will need
its own replay and crash tests; replacement is not claimed to be implemented.

Patch submission separates the engineering session from authoritative state.
It does not yet measure unattended model execution or provider-session recovery.
The fixed seed gives a strong deterministic oracle with a deliberately small
scope. Passing this slice provides no evidence about Windows or vSphere.
