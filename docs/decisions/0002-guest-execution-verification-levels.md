# 2. Guest execution verification levels

## Status

Accepted; planned for Increment 2. The levels describe how work will be proven;
no Increment 2 capability exists yet.

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

Reparse-point confinement belongs here specifically. It cannot be established by
path-string tests, because the defect it guards against is a filesystem
behavior: a component test must create a real junction or symbolic link and
observe the refusal. Increment 1 proved this for source resolution; the guest
side needs its own case.

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

### Guest runtime prerequisite

`ProcessStartInfo.ArgumentList` is a .NET Core 2.1 addition. Windows PowerShell
5.1 runs on .NET Framework, which does not have it, so the decision above is not
merely a coding preference — it is a runtime requirement.

Packer's `powershell` provisioner runs `powershell.exe` by default. The guest
phase therefore sets `use_pwsh = true` and a preflight step asserts the runtime
before anything executes, failing closed if it is absent.

The assertion is a **minimum of 7.4.0**, not "PowerShell 7". A major-version
check accepts releases that have reached end of support, which is the opposite of
pinning: the floor exists to guarantee a runtime that still receives fixes. The
preflight records the observed version in evidence, so a run is attributable to
the runtime that produced it.

Installing PowerShell is not the provisioning phase's job; confirming it is
present, and recent enough, is.

That leaves an obligation for Increment 3: the image build must guarantee the
runtime the guest phase depends on. Whether it arrives as a pinned package in
the manifest or as a base-image property is unresolved, and it is tied to the
base-image decision in section 36. Recording it here means Increment 3 inherits
a stated dependency rather than discovering it when a preflight fails.

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
