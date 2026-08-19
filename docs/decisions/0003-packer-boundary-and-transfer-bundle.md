# 3. Packer boundary for Increment 2, and the verified-only transfer bundle

## Status

Accepted.

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

### The verified-only transfer bundle

A first-class artifact, distinct from host staging and from `-KeepStaging`
diagnostics. It contains only packages that passed host verification.
Unverified content never enters the transfer boundary.

The bundle carries:

- a unique run identity, supplied by the parent rather than invented per stage;
- only verified package files;
- relative paths only, so nothing about the host layout travels with it;
- the expected hashes the guest needs for its own verification;
- an explicit lifecycle with a recorded cleanup outcome.

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
- Increment 3 inherits a proven transfer path and only has to add image
  construction around it.

## Validation implications

The negative lab run is the one that matters. A positive run proves the pieces
connect; only the altered-bundle run proves the guest refuses content that
changed after qualification, and it must show refusal **before** the installer
executes.
