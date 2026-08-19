# 3. Packer boundary for Increment 2, and the verified-only transfer bundle

## Status

Accepted; planned for Increment 2. Nothing in this record is implemented yet.

## Context

Increment 2 owns Packer-controlled transfer into a guest. Increment 3 owns the
image build. Both need Packer, so the boundary between them has to be drawn
explicitly or Increment 2 will drift into base-image selection, which depends on
the unresolved base-image decision in section 36.

There is also a gap left by Increment 1. Host qualification stages packages,
verifies them, and then deletes staging. `-KeepStaging` retains content for
diagnosis, including packages that failed. Neither is a transfer artifact:
uploading a diagnostic directory would move unverified files across the trust
boundary.

## Decision

### Packer scope

Increment 2 contains a runnable harness built on Packer's **null builder**,
targeting an externally supplied disposable Windows host. The null builder runs
provisioners without producing an image artifact, which lets transfer,
execution, restart, and validation be exercised without deciding anything about
image construction.

The harness sequence:

1. create guest staging;
2. upload the verified-only bundle;
3. invoke the guest installation phase;
4. perform one explicit Packer-controlled restart;
5. invoke post-restart validation;
6. download evidence;
7. remove guest staging;
8. evaluate the result only after evidence retrieval and cleanup have been
   attempted.

Step 8 is ordered deliberately. Evaluating earlier would let a failure skip
cleanup and abandon content in the guest.

The restart is owned by the `windows-restart` provisioner, which waits for the
communicator to return within a bounded timeout. Installation logic detects and
reports that a restart is required; it never triggers one.

Explicitly **not** in Increment 2: a vSphere builder or plugin, base-image
selection, installation-media handling, unattended operating-system setup, VM
hardware or storage or network configuration, and generalization, shutdown,
sealing, or artifact publication. Those are Increment 3 and several depend on
the base-image decision.

A loose provisioner fragment is not acceptable. Provisioners need a real build
context, so the harness is a complete, validatable configuration.

Checks introduced with it: a pinned Packer core version, `packer fmt -check
-recursive`, a full `packer validate` rather than `-syntax-only`, and inspection
of provisioner ordering. Lab runs prove two things: a positive run end to end,
and a negative run where the bundle is altered after host qualification and
guest verification rejects it **before** execution.

### Lab-target guard

The null builder connects to an existing machine and mutates it. It does not
create one and it does not dispose of one. Calling the target "disposable" is a
description of intent, and intent is not a safeguard: the same configuration
pointed at the wrong host installs software on that host.

Before anything is uploaded, executed, or restarted:

- there are no default host or credential values. An unset target is an error,
  never a fallback;
- the operator passes an explicit destructive-run acknowledgement. Its absence
  stops the run;
- the intended machine carries a generic marker placed there beforehand — a file
  at a known path containing a nonce that the run is given independently;
- a read-only preflight reads that marker and compares the nonce. A missing or
  mismatched marker stops the run before any mutation.

The marker is the part that actually protects a machine, because it is the only
check that asks the target to prove it is the intended one rather than asking
the configuration to assert it.

Negative tests prove that a missing marker, a mismatched nonce, and an absent
acknowledgement each stop the run before upload.

### Failure and cleanup model

Provisioner ordering does not give evidence retrieval and cleanup. A failing
provisioner ends the build, and by default the provisioners after it never run —
which is precisely the ones that download evidence and remove guest staging.

Two distinct paths, because two distinct things are being handled:

**A logical package failure** — an integrity mismatch, a non-success exit code, a
failed validation — is an expected outcome the run is designed to report. The
guest wrapper writes bounded evidence and exits with either `0` or a single
deliberately chosen logical-result code, and the provisioner lists that code in
`valid_exit_codes`. Packer treats the step as successful, the retrieval and
cleanup provisioners run normally, and a final evaluator reads the retrieved
evidence and fails the build. The build still fails; it fails after the evidence
is on the host rather than instead of collecting it.

**A genuine transport or provisioner failure** — a broken communicator, a
timeout, an upload that could not complete — cannot be reported this way, because
the channel needed to report it is the thing that failed. These stay failures.
Cleanup then depends on an `error-cleanup-provisioner`, which requires the build
to be invoked as:

```text
packer build -on-error=run-cleanup-provisioner
```

Declaring the block is not sufficient. Under the default `-on-error=cleanup` the
error-cleanup-provisioner does not run, so a harness that declares one and
invokes `packer build` plainly has cleanup that never executes — the failure mode
this section exists to prevent.

Host-side `finally` handling covers anything staged on the host, independently of
what the guest side managed.

Cleanup in this second path is recorded as **attempted**, never as guaranteed. If
the communicator is gone, guest staging cannot be removed, and evidence claiming
otherwise would be false.

`continue_on_error` is deliberately **not** used. It was in an earlier draft of
this record, to let logical failures pass through while transport failures
failed. It cannot make that distinction: it applies to any failure of the
provisioner it is set on, so a timeout, a failed script upload, or a lost
communicator would continue into the unconditional restart with the guest in an
unknown state. `valid_exit_codes` distinguishes by what the wrapper deliberately
returned, which is the distinction actually wanted.

### The verified-only transfer bundle

A first-class artifact, distinct from host staging and from `-KeepStaging`
diagnostics. It contains only packages that passed host verification.
Unverified content never enters the transfer boundary.

The bundle carries:

- a unique run identity, supplied by the parent rather than invented per stage,
  and validated as a canonical UUID before it names any directory (ADR 5);
- only verified package files;
- relative paths only, so nothing about the host layout travels with it;
- a **descriptor** carrying everything the guest needs to act;
- an explicit lifecycle with a recorded cleanup outcome.

Files and hashes alone are not enough. The guest has to know what to run, how,
for how long, and what to check afterwards, and it must not re-read or re-derive
that from the manifest — the manifest does not travel, and re-parsing it in the
guest would duplicate the validation the host already performed.

The descriptor is a single JSON document holding, per package: order, identifier,
version, relative payload path, expected SHA-256, installer kind, the MSI
property map or EXE token array, timeout, restart policy, EXE exit-code policy,
and the validation definitions. All of it is data the host already validated
against schema version 2, copied rather than reinterpreted.

#### Establishing that the descriptor is the one the host sent

Schema validation proves a descriptor is well formed. It does not prove it is
*ours*. An attacker able to modify the bundle in transit can rewrite the
arguments, the validation definitions, and the expected payload hashes, then
rewrite the payloads to match those hashes. Everything validates, everything
verifies, and the guest installs whatever it was given.

Recording the descriptor's digest in host-side evidence does not close this. It
makes the substitution *visible to a later reader of host evidence*, after the
guest has already executed. Detection after execution is not a control.

The expected descriptor digest therefore reaches the guest **out of band**,
through the provisioner's `environment_vars` rather than inside the bundle. That
is the same channel that delivers the script itself: an attacker who can rewrite
it is already executing arbitrary code in the guest, so the bundle is no longer
the weak point.

Order matters, and it is: read the raw descriptor bytes, hash them, compare
against the out-of-band expected digest, and only then parse. Parsing first
would mean acting on attacker-controlled structure before authenticating it.

Both digests are recorded in guest evidence, expected and observed, so a
mismatch is legible rather than merely fatal.

The guest treats the descriptor as untrusted input that arrived over a network
until that comparison succeeds. Nothing about the file itself tells the guest
this repository produced it.

Signing the descriptor would be stronger and is the natural successor. It needs
a key, a distribution path, and a rotation story, none of which exist yet, and
an out-of-band digest over a trusted channel closes the immediate hole without
inventing a key-management design in this increment.

Because a file can change between qualification and upload, the bundle is
verified again at the transfer boundary. That is not the same as trusting a
runtime hash: the expected values still come from the manifest.

## Alternatives considered

**Upload host staging directly.** Rejected. Staging is a working directory whose
contents include failures, and its lifecycle is owned by qualification.

**Extend `-KeepStaging` into a transfer mode.** Rejected. It exists for
diagnosis, and overloading it would make an unverified-content path reachable by
a flag intended for troubleshooting.

**Skip re-verification at the transfer boundary.** Rejected. Qualification and
upload are separated in time, and the whole model rests on verifying at each
boundary rather than once.

**Use a vSphere builder now.** Rejected. It forces the base-image decision
early, and nothing about transfer requires it.

## Consequences

- Increment 2 produces a harness that needs an externally supplied target, so
  its Level 3 verification is not available in CI.
- Bundle construction is a new responsibility with its own lifecycle and tests.
- The same content is hashed more than once across a run. That is intended.
- Increment 3 inherits an implemented transfer path carrying its recorded
  verification level, which is not the same as a proven one. If Level 3 is still
  outstanding, Increment 3 inherits that too and must not describe transfer as
  proven.

## Validation implications

Without a disposable target, the only accurate closure statement for this
increment is **implementation complete; lab validation pending**. Landing the
lab-test definitions is not the same as having executed them, and a test that
has never run proves nothing.

The negative lab run is the one that matters. A positive run proves the pieces
connect; only the altered-bundle run proves the guest refuses content that
changed after qualification, and it must show refusal **before** the installer
executes. It must also show that evidence was retrieved and that cleanup was
attempted on both host and guest, since a run that refuses content correctly but
abandons it in the guest has only half worked.

Two tampering cases are needed, not one, because they defeat different controls:

- **payload altered, descriptor untouched** — the per-package hash comparison
  refuses it;
- **descriptor altered, payloads rewritten to match its new hashes** — only the
  out-of-band digest comparison refuses it. This is the case that passes every
  in-bundle check, and a suite testing only the first would report success while
  the interesting attack goes unexercised.
