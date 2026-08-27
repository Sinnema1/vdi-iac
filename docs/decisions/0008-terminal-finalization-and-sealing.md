# 8. Terminal finalization, attestation, and a two-phase seal

## Status

Accepted. Implementation is Increment 3 stage 5, steps 5 to 7, and stage 6.
**Lab-pending in every part that touches a real platform.** Nothing here has run
against vSphere, VMware Tools, Sysprep, or a disposable target.

## Context

Steps 5 to 7 — disable the build account, remove the WinRM listener and its
firewall exception, generalize and shut down — cannot be three provisioners.
Packer reaches the guest over WinRM, so no provisioner can remove the listener
and have a later one open another session. The ordering was never in doubt; the
mechanism was.

That creates the problem this record exists to answer. Once teardown begins the
guest is unreachable, so the usual way of learning whether cleanup worked —
reading evidence back over the connection — is gone. Everything after that point
must be established from outside the guest or not claimed at all.

## Decision

### A detached SYSTEM finalizer owns the terminal transition

The last ordinary provisioner registers and starts a scheduled task running as
SYSTEM, then returns. The finalizer runs in a session that does not depend on
WinRM, so removing the listener does not kill the thing doing the removing.

The finalizer performs, in order, aborting **without shutting down** if any step
fails:

1. re-confirm answer-file residue absence;
2. disable the build account;
3. remove the WinRM listener, disable the service, remove the firewall rule;
4. verify each of the above by re-reading;
5. publish a bounded attestation through VMware Tools;
6. `Sysprep /generalize /oobe /shutdown`.

Publication precedes shutdown because after the machine is down nothing can
publish. Sysprep is reachable only after every gate passes, so a VM that powered
off is a VM whose gates passed — and one that failed stays running, which the
build observes as a shutdown that never came.

### Packer waits for a shutdown it does not perform

`disable_shutdown = true`, with a bounded `shutdown_timeout`.

Leaving the shutdown command empty is not equivalent and would defeat the design:
the builder may then ask VMware Tools to shut the guest down gracefully, which
would power off a VM whose finalizer had failed. The whole fail-closed property
is that a failed finalizer leaves the machine running, and a helpful graceful
shutdown removes exactly that signal. `disable_shutdown` states that the guest
owns its own shutdown and Packer's job is to wait for it.

### Conversion happens outside the Packer build, in a second phase

`convert_to_template` stays `false` permanently. Sealing is a separate host-side
operation that runs after Packer exits:

1. confirm the Packer build succeeded;
2. confirm the VM is powered off;
3. read the attestation, and validate it against its contract;
4. check its run identifier and the host-generated nonce;
5. preserve it in host-side evidence;
6. **clear the transient key**, so clones cannot inherit stale build evidence;
7. convert the powered-off VM to a template;
8. query the resulting artifact identity;
9. emit provenance.

Any failed check leaves the object unconfirmed. It is not named as a candidate,
and the existing `unconfirmedArtifact` field carries what may exist so it can be
reconciled or removed — which is what that field was added for.

This has a consequence worth stating plainly: **the attestation does not need to
survive template conversion**, because it is deliberately consumed and removed
before conversion happens. An earlier sketch depended on `guestinfo` persisting
into the template, which would have made the evidence path rest on behaviour
nobody here has verified.

### VMware Tools is a prerequisite, not an assumption

The attestation channel is VMware Tools' guest RPC interface, so:

- Tools must be installed and running before finalization, and that is checked
  rather than assumed;
- the tool and its version belong in **recipe identity and provenance**. It is
  software installed in the image that changes what the image is;
- failure to find or use the RPC tool is terminal. A finalizer that cannot
  publish must not shut down, because shutting down would produce a powered-off
  VM with no attestation — which the sealing phase would correctly refuse, but
  only after the machine had already generalized itself;
- **no VMware binaries are committed to this repository.** The tool is invoked
  by name from where Tools installs it.

On Windows the interface is `rpctool.exe` or `vmtoolsd.exe --cmd`;
`vmware-rpctool` is the Linux spelling and is not what this path uses.

### The attestation is small, versioned, and boring

It carries only:

- the result schema version;
- the run identifier;
- a host-generated finalization nonce;
- bounded cleanup outcomes;
- a timestamp;
- a terminal result and reason code.

It carries no paths, no installer arguments, no exception text, no credentials,
and no infrastructure identifiers. Exception text is the field that would
otherwise leak all of the others, since a message quotes whatever it failed on.

The key is initialized or cleared **before** the finalizer launches, so a value
found afterwards is one this run wrote. Missing, malformed, oversized, stale,
wrong-run, and wrong-nonce values are all refusals. A missing attestation is an
unverified one, not a probably-fine one.

## Trust boundary

**The attestation reports what the guest claims it performed.** It is useful
operational evidence and it is not independent proof against a compromised
guest: a guest that can publish a result can publish a false one.

Power-off corroborates it and does not replace it. A VM also powers off when it
crashes, when a host action stops it, and when someone clicks the wrong button,
so power-off is consistent with success rather than evidence of it. Both signals
are required, and neither is sufficient.

What the pair does establish is the ordinary case: cleanup that ran and reported
itself, on a machine that then shut down the way the finalizer was written to
shut it down. That is what this evidence is for, and claiming more of it would be
the failure this repository keeps finding in its own earlier work.

## Alternatives considered

**A `shutdown_command` performing teardown.** Rejected: it runs over WinRM, and
the finalizer removes WinRM, so its own channel dies mid-command and Packer
reports a transport error rather than a clean shutdown.

**Reading evidence back after teardown.** Impossible by construction. Recording
it here so nobody proposes it again.

**Writing evidence to a second attached disk.** Rejected for now: reading a VMDK
from outside the guest needs mounting machinery disproportionate to a document
of a few hundred bytes, and the disk would then be part of the sealed artifact.

**Letting `convert_to_template` seal inside the build.** Rejected. It is static
configuration and cannot be conditional, so it would convert whatever the build
produced, including a VM whose finalizer failed but which powered off anyway.

## Consequences

- Sealing becomes a host-side operation with its own evidence, not a Packer
  setting. Increment 3 gains a step that runs after Packer exits.
- The recipe grows a VMware Tools version, which is a new recipe-input version.
- Everything in this record is lab-pending. Tools RPC behaviour, scheduled-task
  survival across WinRM teardown, `Sysprep /shutdown` powering off rather than
  rebooting, vSphere power-state observation, and conversion all need exercising
  against a disposable target before any of it is described as working.

## Validation implications

- The finalizer must be tested through an injected RPC adapter, so its ordering
  and its refusal to shut down after a failed gate are exercised without VMware
  Tools present.
- A test must prove the finalizer does **not** invoke Sysprep when any gate
  fails. Asserting that it publishes a failure is not the same claim.
- The sealing phase must be tested through an injected platform adapter, with
  cases for a powered-on VM, a missing attestation, a stale one from a previous
  run, a wrong nonce, an oversized value, and a malformed document.
- A test must prove the key is cleared before conversion, and that clearing
  failure is itself terminal — a template inheriting a previous build's
  attestation is worse than no attestation.
- The attestation must be searched for credentials and paths, the way the
  recipe-input document already is.
