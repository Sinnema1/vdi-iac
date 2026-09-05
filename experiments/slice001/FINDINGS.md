# Slice 001 review findings

## Initial local milestone

This milestone supports the orchestration contract, not the overall V1 value
proposition. It did not measure reduced human effort or economic value.

The retained local experiment ran against implementation commit `8814055`.
It reached AWAITING_APPROVAL after two executions in approximately 5.06 seconds.
The first execution intentionally supplied an incorrect exit-code repair to
exercise failure handling. The second used the engineering repair after closing
and reopening the database. This is an injected retry test, not an observed AI
reasoning failure or an AI productivity benchmark.

Both executions proved the missing-input seed fails the native regression suite.
The first repair failed that suite. The second passed both the 18-case suite and
the repository public-boundary scan. Its repair restores exit 2; its diff against
the original base is empty. Each attempt retained a separate worktree, patch,
seed diff and validation logs. The successful attempt also retained its repair
diff, base diff and Git tree identity.

No approval was recorded. Human coordination time and cost remain unknown;
wall-clock execution time does not substitute for either measurement.
No branch was pushed and no PR was created, merged or deployed.

## Validation

| Check | Local result |
| --- | --- |
| Orchestration integration tests | 10 passed |
| Native boundary regression suite | 18 passed |
| Public-boundary scanner | Passed |
| ShellCheck | Passed |
| Markdown lint, pinned repository version | Passed |
| PowerShell Pester | 713 passed, 23 skipped, zero failures |
| PowerShell ScriptAnalyzer | Passed |
| Packer formatting | Passed |
| Committed package manifests and media example | Passed |

The Pester run includes Packer configuration validation. Three initial failures
were caused by sandbox restrictions on local plugin sockets; the authorized
rerun passed. No test performed a real lab build. Remote CI has not run, and
Gitleaks was not installed locally; the repository's secret-scan CI gate remains
outstanding before publication is considered validated.

## Findings and limits

Durable intent, execution identity, bounded retries, restart recovery and review
binding are observable with a very small local driver. Integration tests cover
concurrent execution rejection, timeout evidence, retry exhaustion, evidence and
worktree tampering, changed Git HEAD and attempts to modify the test oracle.
The interruption test injects process loss after the durable start; it does not
claim exhaustive power-loss testing at every storage boundary.

The worker handoff is an AI-authored patch file. Automated provider invocation,
model token accounting, unattended scheduling and authenticated remote approval
are not implemented. Worktrees do not contain malicious code. These boundaries
must be addressed before running arbitrary unattended engineering tasks.

Temporal is deferred for this bounded local pilot under ADR 8. The next useful
experiment would replace the operator-driven scheduling and patch handoff while
preserving the Task/TaskExecution and evidence contracts, then compare measured
human attention and cost against a single engineering-session baseline.

## Lifecycle follow-up

The follow-up adds explicit implementation publication approval and resumable
PR creation. It preserves the original execution packet and separately binds
the implementation commit, diff and publication destination. Fifteen local
integration tests pass, including publication gating, stale-state rejection,
restart, uncertain-response recovery and remote-head mismatch checks.

Remote run receipts belong outside the reviewed commit so collecting them does
not change the commit being verified. The measurement protocol has six planned
trial records; no comparative trial or human-effort reduction is claimed.
Temporal remains an option to evaluate against a demonstrated need, not an
automatic V1 dependency. Architectural invariants remain provisional.
