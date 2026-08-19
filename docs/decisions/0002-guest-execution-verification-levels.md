# 2. Guest execution verification levels

## Status

Accepted.

## Context

Increment 2 installs software inside a Windows guest. Most of that work cannot be
proven the way Increment 1 was: installing real software, rebooting a machine,
and waiting for a communicator to return are not things a unit test does.

The risk is not that some behavior goes untested. It is that a stage gets
described as proven when only its formatting was checked. "Packer-controlled
transfer" is the phrase most likely to be claimed on the strength of a passing
`packer validate` and a mocked upload, neither of which moves a byte into a
guest.

## Decision

Verification happens at three named levels, and every capability states which
level proved it.

### Level 1 — CI-proven logic

Runs on every push, on Ubuntu first and Windows as well:

- schema version dispatch and semantic validation;
- verified-bundle construction;
- installer allowlisting;
- argument validation and exact token preservation;
- MSI and EXE exit-code normalization;
- timeout handling;
- restart signaling;
- required and optional aggregation;
- validation aggregation;
- cleanup and bounded evidence.

Where a check would otherwise touch operating-system state, the process,
filesystem, registry, and service boundaries are injected adapters. This keeps
the tests non-destructive and, more usefully, forces those boundaries to be
explicit rather than scattered through the implementation.

### Level 2 — Windows component tests

Runs on `windows-latest` against synthetic fixtures:

- a real child process that records the arguments it received;
- success, failure, timeout, and restart exit codes;
- temporary files and file-version checks;
- temporary user-scoped registry fixtures, if registry validation is added
  later.

The runner is not a Packer guest and must not be treated as one. These tests do
not install real software, create persistent services, or reboot the runner.

### Level 3 — Disposable-guest integration

Requires a real disposable Windows target and proves what nothing else can:
Packer upload, guest-side hash re-verification, installer invocation, a
Packer-owned restart with bounded reconnection, post-restart validation,
evidence retrieval, and cleanup on both sides.

When no disposable target is available, the capability is labelled
**implemented; lab validation pending**. That label is the whole point of the
three levels: it is honest about the difference between code that exists and
behavior that has been observed.

### Argument passing

Installer arguments are passed with `ProcessStartInfo.ArgumentList` and
`UseShellExecute = $false`. Each token is added individually and escaped by the
runtime.

`Start-Process -ArgumentList` is not used. It joins an array into a single
command string, and the receiving process re-splits it. Measured directly, with
three tokens in and four out:

```text
in : INSTALLDIR=C:\Program Files\Example | PROP="quoted" | /norestart

ProcessStartInfo.ArgumentList
  [INSTALLDIR=C:\Program Files\Example]  [PROP="quoted"]  [/norestart]

Start-Process -ArgumentList
  [INSTALLDIR=C:\Program]  [Files\Example]  [PROP=quoted]  [/norestart]
```

An install argument containing a space silently becomes two arguments, and
quoting is lost. Since manifest arguments are untrusted data, that is a
correctness and a safety problem, not a formatting preference.

## Alternatives considered

**Mock the guest and call it proven.** Rejected. It produces a green pipeline
that says nothing about whether a file ever reached a guest.

**Require a disposable guest before the increment can close.** Rejected as a
gate, because it makes progress depend on lab availability. The maturity label
carries the uncertainty instead of the schedule doing it.

**Use `Start-Process` with a pre-quoted string.** Rejected. It moves quoting
into hand-written escaping of untrusted input, which is the mistake the
architecture already forbids for command-string concatenation.

## Consequences

- Every capability in Increment 2 carries a level, and README distinguishes
  CI-proven from lab-proven.
- The process, filesystem, registry, and service boundaries become injected
  adapters, which is more structure than Increment 1 needed.
- Increment 2 can close with Level 3 outstanding, but only while saying so.

## Validation implications

A capability claimed at Level 1 must have a test that fails when the behavior is
removed. This repository has already produced three assertions that passed while
checking nothing, so a passing test is not by itself evidence that a rule holds:
where the cost is low, prove it by mutation.
