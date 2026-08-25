# Agent Handoff and Solution Charter

## 1. Purpose

This document is the durable handoff for engineering agents contributing to this repository. It defines the intended solution, architectural boundaries, delivery sequence, quality expectations, and public-repository constraints.

Treat the current repository as the only source of truth for implemented behavior. This document describes the target direction; it does not prove that a component already exists.

Before changing code:

1. Inspect the repository, current branch, and working tree.
2. Identify what is observed versus proposed.
3. Select the smallest increment that advances the target architecture.
4. Explain how the increment will be validated.
5. Avoid speculative scaffolding for later phases.

### 1.1 Current Implementation Maturity

Describe capability in general terms only. This document states intended
direction; it is not evidence that a capability exists.

`README.md` is the canonical implementation-status summary. It is maintained by
hand, and it is the single place where the state of each area is enumerated. Do
not restate that enumeration here, or in any other document, because two
manually maintained lists diverge and the stale one is read first.

Continuous integration validates the repository's own checks. It does not prove
that any status claim is accurate: a green run means the checks passed, not that
the summary describing the repository is current. When the two disagree, inspect
the repository.

Express maturity as a capability statement rather than a milestone claim. "The
package manifest contract is not yet defined" is useful; "phase one is complete"
asserts something no check can confirm.

## 2. Public Repository Boundary

This is a generic, public reference implementation.

Repository content must not include:

- names identifying individuals, affiliations, or organization-specific identifiers belonging to a non-public context;
- non-public repository names or links;
- internal hostnames, domains, IP addresses, account identifiers, tenant identifiers, or network topology;
- credentials, secrets, certificates, tokens, or private keys;
- proprietary source code, scripts, installer binaries, documents, screenshots, or architecture artifacts;
- non-public ticket numbers, change records, incident details, or operational data;
- values copied from any non-public source, even when they appear harmless.

Naming a technology vendor or product is expected; the stack cannot be described otherwise. What must not appear is any identity, affiliation, or organization-specific identifier belonging to a non-public context.

Use neutral language, fictional identifiers, placeholder addresses, `.example` files, and synthetic test data. Examples should describe only the technologies and architecture patterns required to understand the solution.

If potentially non-public information is supplied during a task, do not reproduce it in the repository. Replace it with an obviously fictional placeholder and call out the substitution.

### 2.1 Public-Safe Technical Detail

The constraint above prohibits specific values. This subsection governs how much
technical detail is publishable once those values are removed.

The test is derivability. Content belongs here when it could be written
independently from public vendor documentation and general engineering
knowledge, and when it makes complete sense to a reader who knows nothing beyond
this repository. Substantive code, contracts, pipelines, and tests are all in
scope on those terms. Depth is not the problem; provenance is.

Some categories reveal origin even after names are stripped, because their shape
is the identifying detail:

| Class | Publishable | Not publishable |
| --- | --- | --- |
| Identifiers | Fictional names, reserved example domains, placeholder addresses | Real hostnames, domains, addresses, account or tenant identifiers |
| Naming conventions | Generic, self-evident schemes invented for this repository | Conventions carrying meaning assigned elsewhere |
| Structure | Patterns explaining an architectural boundary | Exact scale, deployment layout, or approval structure copied from elsewhere |
| Process | Generic promotion, validation, and rollback models | Approval chains, change procedures, or operational history from elsewhere |
| Artifacts | Synthetic fixtures and `.example` files | Configuration values copied from a non-public source |
| Evidence | Illustrative output produced for this repository | Real logs, screenshots, or validation records |
| Checksums | Checksums for publicly available artifacts | Identifiers, filenames, sizes, or fingerprints derived from non-public artifacts |

A checksum for an artifact anyone can download is independently derivable and
carries no information about where it was used. A checksum, filename, or byte
length taken from a non-public artifact is a fingerprint, and remains one after
every name around it has been replaced.

Metadata is content. A directory name, a variable name, a branch name, and a
commit message are all published, and none of them is covered by a check that
reads only file contents.

## 3. Mission

Build a reference architecture for deterministic Windows virtual desktop image creation, infrastructure provisioning, validation, promotion, and lifecycle management using infrastructure-as-code practices.

The solution should demonstrate how to move from manually coordinated or procedural activities toward a Git-based engineering system built around:

- Packer for Windows image construction;
- PowerShell for guest configuration, installation, and validation;
- VMware vSphere as the virtualization platform;
- Terraform for declarative infrastructure and lifecycle orchestration;
- Citrix Machine Creation Services (MCS) for machine catalog provisioning;
- Microsoft Intune for bounded post-provision management validation;
- CI automation for validation, orchestration, evidence capture, and controlled promotion;
- version-controlled definitions and explicit contracts;
- immutable, identifiable image artifacts;
- observable, auditable, fail-closed workflows.

The desired outcome is not maximum automation. It is a solution that is repeatable, deterministic, testable, auditable, maintainable, secure, and understandable.

## 4. Scope

### 4.1 In scope

- Windows virtual desktop base-image engineering;
- persistent or dedicated desktop provisioning patterns;
- deterministic operating-system and software configuration;
- version-pinned build-time software installation;
- package integrity verification before and after transfer to the guest;
- image validation, generalization, shutdown, and sealing;
- immutable image identity and provenance;
- declarative vSphere and Citrix MCS provisioning;
- canary validation before wider promotion;
- explicit promotion, rollback, retirement, and reconciliation concepts;
- bounded Intune enrollment and policy-compliance validation;
- automated tests and durable build evidence;
- clear ownership boundaries among definitions, scripts, CI, and platforms.

### 4.2 Out of scope unless explicitly introduced

- a universal virtual-machine provisioning framework;
- non-Windows operating systems;
- a general endpoint software-deployment product;
- user or device targeting, deployment schedules, or application storefront behavior;
- automatic package discovery or automatic selection of the newest version;
- a general dependency solver;
- a configuration-management replacement;
- a custom secrets platform, artifact platform, workflow engine, or policy engine;
- speculative multi-cloud abstraction;
- production-specific topology or configuration;
- embedding non-public environment details into examples.

## 5. Architectural Principles

1. **Definitions declare.** Manifests, variables, and infrastructure code describe desired state.
2. **Scripts execute.** PowerShell performs bounded imperative work that cannot be expressed declaratively.
3. **Contracts define boundaries.** Schemas and normalized results make handoffs explicit.
4. **Tests prove behavior.** Validation establishes that declared outcomes materially exist.
5. **CI orchestrates.** Pipelines coordinate tools without hiding core logic in pipeline syntax.
6. **Artifacts are immutable.** Published image identity and content do not change in place.
7. **Inputs are pinned.** Exact versions and source references replace `latest`, wildcards, and discovery.
8. **Integrity fails closed.** Missing or mismatched inputs stop the build.
9. **Promotion is separate from construction.** Building an image does not automatically authorize broad use.
10. **Evidence is an output.** Every consequential stage emits enough data to explain its result.
11. **Secrets enter at runtime.** Sensitive values never live in source control or generated evidence.
12. **Least privilege is the default.** Build, validation, and deployment identities receive only required access.
13. **Idempotence is intentional.** Declarative stages converge; imperative stages detect and report current state.
14. **Small increments win.** Add the minimum structure needed for the current accepted work item.

## 6. Architecture Views

Use the following levels when documenting or discussing the solution:

| Level | View | Purpose |
| --- | --- | --- |
| L0 | System context | Actors, external platforms, and trust boundaries |
| L1 | End-to-end lifecycle | Major phases and promotion gates |
| L2 | Logical domains | Ownership and responsibility boundaries |
| L3 | Component interaction | Inputs, outputs, sequences, and failure paths |
| L4 | Implementation | Files, modules, scripts, tests, and pipeline jobs |

Do not confuse architecture hierarchy with runtime sequence, repository hierarchy, delivery backlog, or Terraform state layout. They may relate, but they are different views.

## 7. End-to-End Lifecycle

The target lifecycle contains six phases.

### Phase 1: Source qualification and image build

Qualify pinned inputs, construct a temporary Windows VM with Packer, apply base configuration, install software, validate the build, generalize the operating system, shut down the VM, and seal an immutable candidate image in vSphere.

Phase 1 owns generalization and sealing. Later phases consume the sealed artifact; they do not rebuild or recapture it.

### Phase 2: Image validation and identity

Validate that the sealed candidate is usable and assign durable identity and provenance. Confirm that expected metadata, checksums, software baseline, and build evidence are internally consistent.

### Phase 3: Terraform and MCS canary validation

Use Terraform and Citrix MCS to provision a deliberately limited canary from the candidate image. Validate machine creation, boot, registration, identity, and the minimum required desktop health signals.

### Phase 4: Approval and catalog orchestration

Promote an approved image reference into a controlled catalog configuration. Keep image selection, infrastructure configuration, and approval state explicit. Do not mutate an already published image to represent a new release.

### Phase 5: Intune and operational validation

Confirm bounded post-provision outcomes such as enrollment, expected policy receipt, required service health, and operational readiness. Intune is a validation and management boundary, not the image-construction engine.

### Phase 6: Reconciliation and lifecycle governance

Compare desired and observed state, identify drift, manage rollback and retirement, and preserve lifecycle evidence. Destructive retirement actions require explicit scope and safeguards.

Implementation should begin with the earliest unproven phase and expand only after its contracts and evidence are stable.

## 8. Logical Domains and Ownership

### 8.1 Source qualification

Owns:

- exact source resolution;
- temporary host-side staging;
- pre-transfer SHA-256 verification;
- source metadata capture;
- host staging cleanup.

It does not own guest installation or persistent package hosting.

### 8.2 Image construction

Owns:

- Packer templates and plugins;
- temporary build-VM creation;
- guest communication and file transfer;
- ordered provisioning;
- restart orchestration;
- generalization, shutdown, and sealing;
- Packer build outputs.

### 8.3 Guest provisioning

Owns:

- post-transfer integrity verification;
- installer execution;
- installer exit-code normalization;
- package-specific validation;
- restart-request reporting;
- guest staging cleanup;
- structured package results.

### 8.4 Image validation and provenance

Owns:

- sealed-artifact validation;
- immutable image identity;
- mapping image identity to source revision and build evidence;
- readiness decision for canary use.

### 8.5 Infrastructure provisioning

Owns:

- Terraform configuration and state boundaries;
- vSphere objects required by the selected desktop pattern;
- Citrix MCS catalog and machine lifecycle declarations;
- canary sizing and bounded rollout configuration;
- infrastructure output contracts.

### 8.6 Operational validation

Owns:

- machine boot and registration checks;
- desktop health validation;
- bounded Intune checks;
- release readiness evidence;
- explicit pass, fail, and inconclusive outcomes.

### 8.7 Promotion and lifecycle

Owns:

- candidate-to-approved transitions;
- catalog image-reference updates;
- rollback selection;
- superseded artifact retention or retirement;
- desired-versus-observed reconciliation.

### 8.8 Installation-media qualification

Settled by [ADR 6](docs/decisions/0006-base-image-from-installation-media.md):
builds construct from installation media, so this domain applies. It owns:

- resolution of an exact media reference;
- verification against a separately published checksum;
- media availability to the build execution context;
- media identity recorded in provenance.

It does not own guest package installation. Media does not travel the guest
package-staging path described in section 13, though it may be mounted or
otherwise presented to the build VM by other means.

It also owns the unattended answer file that drives setup. The file requires an
administrator password, so the repository holds a template with placeholders and
values are injected at runtime. Rendering fails closed on an unsubstituted
placeholder, and a rendered file is never written into the repository tree.

## 9. Primary System Flow

```text
Version-controlled definitions
          |
          v
Input qualification and integrity checks
          |
          v
Packer Windows image construction
          |
          v
Generalize, shut down, and seal
          |
          v
Immutable candidate image + provenance
          |
          v
Terraform and Citrix MCS canary
          |
          v
Technical and operational validation
          |
          v
Explicit approval and promotion
          |
          v
Catalog rollout, reconciliation, and retirement
```

Every arrow is a contract boundary. Inputs, outputs, ownership, validation, and failure behavior should be documented before coupling phases together.

## 10. Build-Time Software Model

The initial package source may be a read-only file share or another version-addressable package source. The architecture must not depend on automatic package discovery.

Required properties:

- the build identity can read only the required package paths;
- package references identify exact versions;
- package files are not committed to Git;
- the Windows guest does not receive package-source credentials;
- package contents are staged temporarily by the controlled build execution context;
- expected hashes are established before build runtime;
- unverified content never reaches installer execution;
- host and guest staging are removed after results are preserved.

A later artifact repository can replace the source adapter without changing the manifest's trust model or the guest installation contract.

**Artifact classes.** Software packages and installation media are distinct
classes with distinct qualification paths, and conflating them produces a
manifest that tries to describe both badly.

| | Software package | Installation media |
| --- | --- | --- |
| Described by | A manifest entry with an expected SHA-256 | A media reference qualified against a separately published checksum |
| Typical size | Megabytes to hundreds of megabytes | Gigabytes |
| Guest package-staging path | Yes, staged host-side then transferred | No; media may instead be mounted or otherwise presented to the build VM |
| Verified | Host-side, then re-verified in the guest | At acquisition, and again at each transfer or publication boundary it crosses |

This section describes the package model.
[ADR 6](docs/decisions/0006-base-image-from-installation-media.md) settles where
a build begins: from installation media, qualified by section 8.8. The two
classes stay separate regardless -- a manifest describes packages, never media.

## 11. Package Manifest Contract

One manifest normally describes the ordered software recipe for one image baseline.

Manifests are JSON. The serialization and validation approach is recorded in
[ADR 1](docs/decisions/0001-package-manifest-serialization.md).

Schema version 1, as implemented:

```json
{
  "schemaVersion": 1,
  "packages": [
    {
      "id": "example-agent",
      "version": "1.2.3",
      "source": "file://example-agent/1.2.3/agent.msi",
      "sha256": "<64-character-lowercase-hex-value>",
      "order": 20,
      "required": true
    }
  ]
}
```

The contract is `contracts/package-manifest.schema.json`. It sets
`additionalProperties: false` at both levels, so a manifest carrying a field
this version does not consume is rejected rather than silently accepted.

Fields arrive with the increment that consumes them. Schema version 1 carries
only what source qualification uses:

- schema version;
- package ID;
- package version;
- exact source reference;
- expected SHA-256;
- install order;
- required/optional status.

Deferred to the increment that implements installation and post-install
validation:

- installer type;
- installer input represented safely: an argument token array for EXE packages, and an allowlisted property map for MSI packages, per [ADR 4](docs/decisions/0004-package-manifest-schema-2.md);
- a bounded validation definition.

The manifest is an image recipe. It must not acquire endpoint-deployment concepts such as assignments, schedules, audience targeting, package search, update channels, or general dependency resolution.

Treat installer input as untrusted data. Avoid command-string concatenation and pass each token individually through explicit process argument handling, never through a joined string. For MSI packages the executor owns the command line entirely and a manifest supplies only allowlisted properties, so it cannot pass a switch at all.

## 12. Integrity and Trust Model

The expected SHA-256 must come from a trusted qualification step before the build starts. When available, compare the qualified package against a vendor-published checksum.

Never calculate a hash at runtime and then treat that same value as the expected hash.

```text
Expected SHA-256 in version-controlled manifest
                    |
                    v
       Retrieve exact package source
                    |
                    v
        Calculate host-side SHA-256
                    |
             match / mismatch
                |         |
                v         v
        Packer transfer   fail
                |
                v
        Calculate guest SHA-256
                |
             match / mismatch
                |         |
                v         v
             install      fail
```

Use the same expected hash at both verification boundaries. A missing file, inaccessible source, malformed hash, or mismatch is a terminal failure for a required package.

## 13. Canonical Package Provisioning Sequence

1. Parse the manifest.
2. Validate its schema and semantic constraints, dispatching on the declared schema version.
3. Sort packages deterministically.
4. Resolve each exact source reference.
5. Copy the package into unique temporary host staging.
6. Calculate the host SHA-256 and compare it with the manifest.
7. Assemble a verified-only transfer bundle with its descriptor, covering only packages that passed step 6.
8. Transfer the bundle through Packer, and pass the expected descriptor digest out of band.
9. Compare the descriptor digest in the guest before parsing it.
10. Calculate the guest SHA-256 for each package and compare it with the same expected value.
11. Execute the installer with individually passed arguments or properties.
12. Normalize the process result and the restart requirement.
13. Record a structured package result carrying bounded reason codes.
14. Continue according to required/optional failure policy.
15. Aggregate the package results.
16. Perform the single Packer-owned restart, unconditionally, after the batch.
17. Validate installed state on the far side of the restart.
18. Retrieve evidence from the guest.
19. Attempt guest staging removal, recording the outcome.
20. Attempt host staging removal, recording the outcome.
21. Evaluate the aggregate result and decide the build outcome.

Order is deliberate in three places, each recording a lesson rather than a
preference. Validation follows the restart, because a check run before a pending
reboot observes a state the machine will not be in afterwards. Evidence
retrieval precedes cleanup, because cleanup can fail and evidence collected
afterwards may be gone. Evaluation is last, because a run that fails before
retrieving evidence has destroyed the explanation of its own failure.

Do not silently continue after an integrity failure. A required package failure must fail the image build. Optional-package behavior must be explicit and visible in the aggregate result.

## 14. PowerShell Responsibilities

PowerShell should remain small, explicit, and testable.

Preferred characteristics:

- strict error behavior;
- explicit parameters and validated input;
- structured objects rather than formatted text as internal output;
- native process invocation without unsafe string evaluation;
- deterministic exit-code mapping;
- clear distinction among success, success-with-restart, and failure;
- idempotent checks where reruns are plausible;
- `try`/`finally` cleanup around temporary resources;
- redaction of secrets and sensitive runtime values;
- logs suitable for both humans and CI ingestion.

Initial installer support should normally be limited to MSI and explicitly integrated EXE packages. Do not introduce a plugin framework, dependency-injection container, resumable workflow engine, or package-management product without demonstrated need.

## 15. Post-Install Validation

Installer exit code `0` proves only that a process reported success. Each package needs the minimum material validation appropriate to it, such as:

- expected file and file version;
- Windows service existence, configuration, or state;
- registry value;
- executable version output;
- application registration;
- agent health command.

Validation definitions must be bounded and allowlisted. Do not execute arbitrary manifest-provided PowerShell.

Validation produces one of three explicit outcomes:

- `passed` — the expected state is observed;
- `failed` — the expected state is not observed;
- `inconclusive` — the check could not establish a result.

For required packages, both `failed` and `inconclusive` fail the build unless the contract explicitly defines safer behavior.

## 16. Restart Handling

Installation logic detects and reports a restart requirement. Packer owns the actual restart boundary and confirmation that the guest becomes available again.

Restart behavior must be deterministic:

- known installer restart codes are normalized;
- pending restart state is observable;
- restart placement is explicit in the build sequence;
- guest reconnection has a bounded timeout;
- validation occurs on the correct side of the restart boundary.

Do not build a persistent deployment state machine solely to handle build-time restarts.

## 17. Image Construction and Sealing

A candidate image should be constructed from pinned inputs and a recorded source revision. The build sequence should make these boundaries visible:

1. base image selection;
2. temporary VM construction;
3. operating-system configuration;
4. software provisioning;
5. pre-generalization validation;
6. cleanup of transient state;
7. generalization;
8. shutdown confirmation;
9. vSphere sealing or capture;
10. artifact identity and metadata publication.

No post-seal process should modify the candidate in place. A required content change produces a new build and a new identity.

## 18. Image Identity and Provenance

An image identity should map unambiguously to its construction inputs. Avoid using a mutable display name as the sole identifier.

Evidence should be able to associate the image with:

- source revision;
- Packer template and plugin versions;
- base image identity;
- manifest revision or digest;
- package IDs, versions, sources, and expected hashes;
- host and guest verification results;
- build timestamp and build-run identifier;
- validation results;
- sealed vSphere artifact identifier;
- promotion status.

Do not place credentials, complete environment exports, or unnecessary machine data into provenance records.

## 19. Terraform Design Direction

**PROPOSED.** No Terraform configuration exists. This section states intended design, not implemented behavior.

Terraform should express desired infrastructure state and consume an explicitly approved image reference. It should not build images or contain large procedural scripts.

Design expectations:

- pin Terraform and provider versions;
- separate reusable modules from deployable root configurations;
- keep environment values outside reusable modules;
- expose small, documented input and output contracts;
- use remote state and locking when a shared backend is introduced;
- treat state as sensitive;
- avoid secrets in variables, plans, outputs, and logs where possible;
- make destructive changes visible and reviewable;
- do not use provisioners as a general configuration mechanism;
- validate inputs and use stable resource addressing;
- document import and drift-handling expectations.

State boundaries should follow lifecycle ownership and blast radius. Image construction, shared platform objects, catalog definitions, and individual machine lifecycles should not be combined automatically into one state merely because they participate in one end-to-end flow.

## 20. Citrix MCS Design Direction

**PROPOSED.** No Citrix integration exists. Provider and module boundaries are unresolved -- see section 36.

Citrix MCS consumes the sealed, approved vSphere image through declarative catalog configuration.

The integration should make these concepts explicit:

- hosting connection or platform reference;
- provisioning scheme;
- machine catalog identity;
- desktop persistence model;
- machine count and naming strategy;
- organizational placement expressed only through generic variables;
- image version/reference;
- bounded canary configuration;
- registration and health validation;
- rollback to a previously approved image reference.

Avoid embedding platform credentials or private topology in Terraform. Treat delivery assignment and published-application concerns as separate modules or later scopes unless a requirement directly couples them.

## 21. Intune Boundary

**PROPOSED.** No Intune integration exists. The query and validation mechanism is unresolved -- see section 36.

Intune participation is deliberately bounded. The image build should prepare only prerequisites that genuinely belong in the base image. Runtime validation may confirm:

- expected enrollment state;
- device identity correlation;
- receipt of required policy;
- health of required management services;
- compliance or readiness signals that can be queried safely.

Do not duplicate Intune policy in Packer or Terraform. Do not turn this repository into a general Intune configuration repository unless the scope is explicitly changed.

## 22. Promotion, Rollback, and Retirement

**PROPOSED.** No lifecycle state is tracked anywhere in the repository. The states below are a model, not a record of anything that runs.

Use explicit lifecycle states rather than inferring approval from a filename or successful build.

Conceptual states:

```text
built -> validated -> canary -> approved -> promoted -> superseded -> retired
```

A transition should record:

- source and target state;
- image identity;
- evidence evaluated;
- decision timestamp;
- automation or actor category, without personal data;
- resulting catalog or deployment reference.

Rollback selects a previously approved immutable image and applies the same controlled orchestration path. It does not edit or reconstruct the prior image.

Retirement is destructive and should require dependency checks, explicit targeting, and a documented retention policy.

## 23. Reconciliation and Drift

**DEFERRED.** Reconciliation depends on provisioned infrastructure to compare against, and none exists. Recorded here so the boundary is designed before it is needed.

Reconciliation compares declared intent with observable platform state. It should distinguish:

- expected transitional state;
- benign descriptive drift;
- correctable configuration drift;
- security- or availability-relevant drift;
- orphaned infrastructure;
- state that requires human review.

Automated correction must be limited to well-understood, reversible actions. Discovery of drift is not blanket authorization to destroy or replace resources.

## 24. Evidence and Observability

Evidence is a first-class product of every phase.

Use normalized, machine-readable results where practical. Common fields may include:

- schema version;
- run identifier;
- stage and component;
- source revision;
- artifact identity;
- start and completion timestamps;
- outcome and reason code;
- validation summaries;
- tool versions;
- links or references to retained logs and reports.

Logging should be structured, timestamped, and explicit about stage boundaries. Redact secrets and minimize infrastructure identifiers. Evidence retention belongs to CI or an external evidence store, not necessarily Git.

## 25. Security Model

Apply these controls from the first increment:

- no secrets or private material in Git;
- runtime secret injection through an appropriate secret provider;
- separate identities for build, validation, and deployment where practical;
- least-privilege platform and package-source access;
- short-lived credentials when supported;
- checksum verification for all external binary inputs;
- pinned tool and provider versions;
- redacted logs and failure messages;
- temporary resource isolation and cleanup;
- dependency and static analysis in CI;
- review of Terraform plans before apply;
- no direct guest authentication to the package source;
- no arbitrary code execution from manifest fields.

Provide `.example` configuration with placeholders and document required secret names without providing values.

## 26. Failure and Recovery Model

Failure behavior must be designed, not incidental.

- Invalid definitions fail before expensive build work.
- Missing or unverifiable inputs fail closed.
- Required package failures fail the image build.
- Cleanup runs even when the main operation fails, while preserving the original error.
- Temporary VM or staging cleanup is retryable and observable.
- Partial infrastructure application is reconciled through Terraform, not ad hoc deletion.
- Inconclusive validation blocks promotion.
- Promotion failure leaves the last approved version identifiable.
- Rollback uses an immutable known-good artifact.
- Destructive recovery steps require explicit, validated targets.

Retries should be bounded and limited to transient operations. Do not retry deterministic validation or integrity failures as if they were transient.

## 27. Testing Strategy

Use a test pyramid that keeps feedback fast and full image builds intentional.

### Static and contract checks

- Markdown and YAML linting;
- Packer formatting and validation;
- Terraform formatting, validation, and provider lock verification;
- PowerShell analysis;
- manifest schema and semantic validation;
- secret scanning;
- dependency or policy checks where justified.

### Unit tests

- source-reference validation;
- SHA-256 comparison;
- manifest ordering and failure policy;
- installer command construction;
- exit-code normalization;
- structured result creation;
- cleanup behavior;
- evidence redaction.

### Integration tests

- temporary source staging;
- transfer and guest hash verification;
- representative MSI and EXE installation;
- restart orchestration;
- Packer template integration;
- Terraform plan behavior with synthetic inputs.

### End-to-end tests

- complete image build;
- sealed-image validation;
- bounded MCS canary;
- registration and operational checks;
- promotion and rollback rehearsal.

Favor inexpensive tests first. Run full builds only when earlier gates pass and the change justifies their cost.

## 28. CI/CD Direction

Keep pipeline configuration thin and route logic to versioned scripts or standard tool commands.

Conceptual stages:

1. repository policy and secret scan;
2. format, lint, and static analysis;
3. schema and contract validation;
4. unit tests;
5. Packer and Terraform validation;
6. source qualification;
7. candidate image build;
8. artifact and evidence publication;
9. sealed-image validation;
10. canary plan and controlled apply;
11. operational validation;
12. explicit promotion;
13. scheduled reconciliation.

Not every stage belongs in the first implementation. Introduce a stage only when the repository contains the responsibility it validates or orchestrates.

## 29. Repository Design Direction

The following structure is a destination map, not a request to create empty directories:

```text
<repository-root>/
├── README.md
├── Agent_Handoff.md
├── .gitignore
├── .continue/
│   └── rules/
├── docs/
│   ├── architecture/
│   ├── decisions/
│   ├── contracts/
│   └── operations/
├── packer/
│   ├── templates/
│   ├── variables/
│   ├── manifests/
│   ├── schemas/            PROPOSED
│   ├── sources/            Increment 3
│   │   └── windows/        Increment 3
│   ├── unattended/         Increment 3
│   ├── validation/         PROPOSED
│   ├── scripts/
│   │   ├── packages/
│   │   ├── validation/
│   │   └── cleanup/
│   └── tests/
├── source-qualification/
│   ├── scripts/
│   └── tests/
├── terraform/
│   ├── modules/
│   └── roots/
├── contracts/
├── scripts/
│   └── ci/
└── tests/
    ├── fixtures/
    └── integration/
```

Paths marked PROPOSED are candidates, not commitments: `schemas/` and
`validation/` presuppose the shape the manifest contract takes. Paths marked
Increment 3 are committed by
[ADR 6](docs/decisions/0006-base-image-from-installation-media.md), which
selects media-based construction, but do not exist yet.

Create paths only when implementing their responsibility. Prefer one clear implementation over parallel examples that can drift.

## 30. Documentation and Decision Records

Documentation should explain current behavior and durable decisions, not speculate about every future option.

Create an architecture decision record when a choice:

- changes a public or cross-domain contract;
- establishes a security or trust boundary;
- selects a state or lifecycle boundary;
- introduces a major dependency;
- is difficult or costly to reverse;
- rejects a plausible alternative for a durable reason.

Each decision record should contain context, decision, alternatives, consequences, status, and validation implications. Do not create decision records for routine file edits.

## 31. Engineering Standards

### PowerShell

- use approved verbs and explicit parameters;
- prefer small functions with single responsibilities;
- return structured data;
- use terminating errors for failed required operations;
- test exit codes and external-command behavior;
- avoid global mutable state;
- make cleanup safe and repeatable;
- keep secrets out of commands and logs.

### Packer HCL

- pin required plugins;
- separate templates from private variable values;
- keep provisioner boundaries readable;
- use communicators and timeouts explicitly;
- do not duplicate authoritative image definitions;
- expose build outputs in a machine-readable form.

### Terraform HCL

- format and validate every change;
- pin versions and commit dependency locks where appropriate;
- use typed variables and validations;
- mark sensitive values correctly while assuming state still requires protection;
- keep modules cohesive and outputs minimal;
- avoid dynamic abstraction until repeated use justifies it.

### YAML, JSON, and Markdown

- validate machine-consumed files against a schema when the boundary warrants it;
- keep examples fictional and executable after placeholder substitution;
- use stable field names and explicit schema versions;
- keep human guidance close to the component it explains.

## 32. Delivery Sequence

Use this sequence as the strategic roadmap. Every increment beyond the one
currently in progress is **PROPOSED**: the contents below are a plan, and
earlier contracts may reshape later increments as implementation evidence
emerges. Consult README for which increment is actually current.

### Increment 0: Repository foundation

- public-safe README and contribution guidance;
- ignore rules and example configuration;
- agent rules and architectural glossary;
- baseline linting and secret scanning.

### Increment 1: Manifest and source integrity

- minimal package manifest contract;
- schema and semantic validation;
- exact source resolution;
- host staging and SHA-256 verification;
- unit tests and structured results.

### Increment 2: Guest package provisioning

**Status: implementation complete; lab validation pending.** Every acceptance
criterion below is met and CI-proven or component-proven. The transfer,
installer execution, restart boundary, and post-restart validation have never
run against a Windows guest, and the three lab scenarios have never executed.
Closing the increment records what was built, not that it works in a lab.

- Packer-controlled transfer;
- guest hash re-verification;
- bounded MSI/EXE execution;
- post-install validation;
- restart signaling and cleanup;
- package evidence aggregation.

Governed by [ADR 2](docs/decisions/0002-guest-execution-verification-levels.md),
[ADR 3](docs/decisions/0003-packer-boundary-and-transfer-bundle.md),
[ADR 4](docs/decisions/0004-package-manifest-schema-2.md), and
[ADR 5](docs/decisions/0005-evidence-versioning-and-run-identity.md).

Implementation order, each stage landing before the next begins. **Every stage
includes its own positive, negative, and regression tests**; a stage is not
complete without them. Deferring tests to a later stage would contradict both
the Definition of Done and ADR 2.

1. the version 1 digest guard, the version 2 schema, and the version dispatcher.
   The digest guard is itself a test, and every schema rule needs a case proving
   it rejects;
2. the verified-only bundle lifecycle, including the descriptor and its
   integrity binding;
3. guest verification, execution, validation, cleanup, and evidence, with the
   process, filesystem, and service boundaries injected so the tests are
   non-destructive;
4. cross-cutting regression coverage and Windows component tests -- the real
   child process, real exit codes, and a real junction or symbolic link. This
   stage adds what needs a Windows runner, not the tests stages 1 to 3 owed;
5. the null-builder Packer harness, its lab-target guard, and its lab tests.

Acceptance criteria:

- `contracts/package-manifest.schema.json` is byte-for-byte immutable and must
  not be edited, descriptions included. Version 2 is a new file, and a test
  asserts the version 1 digest;
- dispatch uses a hard-coded version map, never a path built from a declared
  value and never a fallback to the newest schema;
- a version 1 manifest that validated before this increment still validates
  after it, proven by a test;
- unverified content never crosses the transfer boundary, and the bundle is
  re-verified there;
- installer arguments are passed as individual tokens, never as a joined string;
- Packer owns the restart boundary; installation logic reports that a restart is
  required and never triggers one;
- evidence carries `ResultSchemaVersion` and `ManifestSchemaVersion`, a
  parent-supplied run identifier, and none of the excluded values in ADR 5;
- the run identifier is a validated canonical UUID before it names any
  directory;
- no log holds installer arguments or property values, only bounded metadata.
  An MSI writes its own verbose log inside the guest staging root, which does
  contain properties; it is never retrieved, and cleanup removes it with the
  root. Do not add it to the download set;
- the lab harness refuses to run without an explicit acknowledgement and a
  matching marker on the target;
- evidence retrieval and cleanup are attempted on both the logical-failure and
  transport-failure paths, with cleanup recorded as attempted rather than
  guaranteed;
- the guest staging root is host-controlled, delivered independently of the
  uploaded bundle, and never read or derived from the descriptor. Cleanup has to
  work after descriptor tampering, so what gets deleted must not depend on a
  document an attacker may have rewritten;
- every capability states its verification level. Without a disposable target
  the increment closes as **implementation complete; lab validation pending**,
  and landing lab-test definitions does not substitute for running them.

Known follow-up, not blocking: a top-level `failed` result containing an
`incomplete` package should normalize to `incomplete`. Neither value permits
success or authorizes a restart, so the current behavior is safe and the
correction is about reporting accuracy rather than a control gap. Fix it when
the lab run gives a reason to touch this path.

Explicitly deferred to Increment 3: any vSphere builder or plugin, base-image
selection, installation-media handling, unattended setup, VM hardware, storage
or network configuration, and generalization, shutdown, sealing, or publication.
Several depend on the base-image decision in section 36.

### Increment 3: Image build and sealing

The deliverable is **one sealed candidate image with stated provenance**. Not a
published one, not a validated one -- those are Increments 4 and beyond. An
image that cannot be identified or whose inputs cannot be stated does not count,
because identity and provenance are what make the artifact usable later.

Governed by [ADR 6](docs/decisions/0006-base-image-from-installation-media.md),
which selects construction from installation media.

- installation-media qualification;
- unattended answer-file contract;
- complete Packer template, with base-image and tool version pinning;
- pre-generalization checks;
- generalization, shutdown, and vSphere sealing;
- immutable identity and provenance.

**Deferred: artifact publication and reference resolution.** Increment 3 needs
only enough to identify and preserve the candidate. Content Library, or whatever
replaces it, would have no role until there is a sealed artifact to publish, and
selecting one now would settle an open decision as a side effect of building
something else. Section 36 keeps it open.

Implementation order, each stage landing before the next begins, and **every
stage includes its own positive, negative, and regression tests**. The order is
deliberate: everything provable without a lab comes first, so the untestable
surface is as small as possible when a target finally exists.

1. media qualification -- **complete, CI-proven**. An exact media reference
   resolved and verified against a separately published checksum, with evidence.
   Host-side.

   Scope, stated so it is not overread: this stage **fingerprints the artifact
   and records the declared installation selection**. It does not open the media,
   so it does not establish that the edition, index, architecture, and language
   are what the reference claims. Those are intent. The pre-seal checks in
   stage 5 compare the operating system actually installed against that intent,
   which is where the claim is settled. Do not add ISO-inspection tooling to
   make this stage's wording stronger;
2. the answer-file contract. Maturity differs by part, so it is stated by part
   rather than as one label:

   | Part | State |
   | --- | --- |
   | Host renderer and credential handling | complete, CI-proven |
   | Template and declaration contract | complete, CI-proven |
   | Guest setup-residue sweep | implemented, CI-proven against fixtures; **lab-pending** against a real guest |
   | Build-credential disable or rotation | **not implemented**; planned for stage 5, before sealing |
   | Operational answer file and Windows SIM validation | **stage 4**; the committed template covers image selection and the credential positions, not a full hardware, disk, and network configuration |

   A committed template, runtime substitution, and a fail-closed check for
   unsubstituted placeholders. No rendered file ever enters the repository tree.

   The stage **defines** the whole credential lifecycle and **implements the
   host part** of it: the value arrives as a sensitive runtime input, never on a
   command line, in a log, or in evidence; the rendered file is written to a
   restricted location this repository owns, and is removed on every exit path
   including failure, with a failed removal making the run fail. The guest
   residue sweep is implemented and proven against fixtures. Disabling or
   rotating the build credential is defined here and **implemented in stage 5**,
   before sealing, so that a sealed image never carries a working one. The table
   above is authoritative on what exists today;
3. image identity and the provenance record -- CI-provable. Three identities
   stay distinct and all three are bound together in provenance, because
   collapsing any two makes a question unanswerable:

   | Concept | Answers |
   | --- | --- |
   | `recipeDigest` | what was built -- the identity of the construction inputs |
   | `runId` | which execution built it |
   | vSphere artifact identity | which immutable artifact resulted |

   Two builds from identical inputs share a `recipeDigest` and differ in `runId`
   and artifact identity. A rebuild after any input changes differs in all three.
   The record links an image to its media reference, manifest and schema version,
   package identities and hashes, answer-file revision, and tool versions.

   Settled by [ADR 7](docs/decisions/0007-image-identity-and-provenance.md),
   which fixes the canonical `recipe-input-1` document, what it includes and
   excludes, and how every value is represented. Implementation obligations that
   follow from it:

   - `evidence-envelope-2` is preserved byte-for-byte. Version 3 is a new file,
     dispatch is a hard-coded version map, and a test asserts a version 2
     document that validated before still validates;
   - any common envelope rule duplicated into version 3 gets a parity test, as
     the manifest and transfer contracts already do. Repeated shapes drift;
   - version 3 carries the same semantic control-character rejection the package
     and transfer paths have. Schema patterns stay ECMA-262 compatible, so the
     gap cannot be closed inside the schema;
   - artifact identity is required only for a positively sealed result. Failed,
     incomplete, and pre-seal records omit it, and absence is not corruption;
   - artifact identity is the vCenter instance scope, the managed object
     reference, and the VM instance UUID. The recorded name is display metadata
     and never an identifier. All of it is environment-specific, excluded from
     `recipeDigest`, and only observable in a lab-produced record;
4. the vSphere builder configuration -- source definition, pinned plugin
   versions, hardware and boot configuration, and the media reference. It
   consumes the Stage 1 qualification record and reverifies the media at its own
   input boundary, because a check performed by an earlier stage is a claim
   about the past. Closes as **configuration validated in CI; execution lab
   pending**: `packer validate` resolves references a syntax check would not,
   and proves nothing about vSphere connectivity, media reachability, boot
   behavior, or whether the build converts to a template;
5. pre-generalization checks, generalization, shutdown, and sealing, with
   evidence at each boundary. **Lab-only**; nothing here is CI-provable.

   Sealing is a positive gate, not the absence of a failure. An artifact may be
   called a sealed candidate only when every one of these is affirmatively
   true: pre-generalization checks succeeded; generalization succeeded;
   shutdown was observed rather than assumed; credential and answer-file residue
   is absent; and the provenance record is complete. Anything less produces an
   artifact that is not a candidate, and it must not be named as one;
6. provenance emission at seal time, binding the identity to the record.
   Lab-only, and the point at which a candidate becomes nameable.

Acceptance criteria:

- media is verified against a checksum published separately from the artifact.
  A value read from beside the artifact it claims to verify is not a check, and
  a runtime-computed hash treated as expected is the failure the glossary names;
- a media mismatch fails the build, proven by a test that supplies a mismatch;
- this repository holds the synthetic `.example` reference only, under
  `packer/media/**/*.media.json.example`. A live media reference names a real
  artifact, its digest, and where it came from, and is version-controlled in a
  private or otherwise access-controlled repository that consumes this one to
  operate a build. CI searches the whole tree for `*.media.json`, not only the
  conventional directory, because a live reference dropped anywhere else is
  exactly as published;
- the qualification record is machine-consumed, not prose: an exact media
  reference, the hash algorithm and expected digest, the independently obtained
  checksum authority the digest came from, the selected edition or image index,
  and the architecture and language. A build that guesses any of these is not
  deterministic;
- the builder reverifies the media against that record at its own input
  boundary. Stage 1 verifying it once is a statement about the past;
- the **committed template** carries no credential, and rendering fails closed
  on an unsubstituted placeholder. The **rendered runtime file is an ephemeral
  secret**: it holds a working credential for as long as it exists, so it is
  written to a restricted location, removed on every exit path, and never
  described as safe merely because the template was. The boundary check sees the
  template, never a rendered copy;
- image identity is derived from construction inputs. A timestamp, a display
  name, or a sequence number is not an identity, and a test asserting only that
  some identifier exists would accept all three;
- the provenance record names the media reference and checksum, the manifest and
  its schema version, package identities and hashes, the answer-file revision,
  and the tool versions. It is emitted under **the evidence contract the Stage 3
  ADR selects** -- `evidence-envelope-2` has closed payloads and a bounded
  `resultKind`, so an image-build result does not belong to it by default and
  adding one is a contract change, not an enum edit;
- the answer file's image selection agrees with the qualified media reference.
  Media qualification records intent without opening the media, and the answer
  file is what actually tells setup which image to install, so a disagreement
  means the build installs something other than what provenance will name;
- the build credential is disabled or rotated before sealing -- stage 5 work,
  not stage 2 -- and the sealing gate reads the residue sweep's result rather
  than assuming it ran;
- the answer file the build actually uses is completed in stage 4, with a full
  hardware, disk, and network configuration and validation against Windows
  System Image Manager. Stage 2 establishes the contract and the credential
  path, not a production-ready answer file;
- the pre-seal checks compare the installed operating system -- its edition,
  architecture, and language -- against the intent declared in the media
  reference. Media qualification proved the artifact's identity, not its
  contents, and this is where the two are reconciled;
- generalization runs before shutdown, and sealing after it. A sealed image that
  was never generalized cannot be cloned safely, and ordering asserted only by
  reading configuration text is the gap Increment 2 closed twice;
- a candidate image is never modified in place. A content change produces a new
  build and a new identity;
- **no image is described as sealed until a real vSphere build has completed and
  produced the provenance record.** Stages 1 to 3 close as CI-proven. Stage 4
  closes as **configuration validated in CI; execution lab pending** -- it is not
  CI-proven, because nothing in CI runs it. Stages 5 and 6 close as
  implementation complete, lab validation pending.

### Increment 4: Sealed-image validation

- isolated candidate validation;
- readiness contract;
- evidence publication;
- explicit rejection behavior.

### Increment 5: Terraform and MCS canary

- initial provider and state design;
- reusable catalog/provisioning modules;
- bounded canary root configuration;
- plan review, apply, registration, and health validation.

### Increment 6: Promotion and operational validation

- explicit approval contract;
- catalog image-reference promotion;
- bounded Intune validation;
- rollback rehearsal.

### Increment 7: Reconciliation and retirement

- desired-versus-observed checks;
- drift classification;
- safe remediation boundaries;
- retention and retirement workflow.

Do not begin a later increment merely to create placeholders. Earlier contracts may evolve as implementation evidence emerges.

## 33. Definition of Done

A meaningful change is complete when:

- its scope and non-goals are clear;
- public-repository constraints are satisfied;
- implementation matches the current architecture and ownership boundary;
- inputs and outputs are documented;
- failure and cleanup behavior are explicit;
- relevant tests pass;
- formatting, validation, and static checks pass;
- secrets and non-public identifiers are absent;
- the complete diff has been read for non-public content, with the automated
  checks treated as a floor rather than a substitute;
- evidence needed to explain the result is produced;
- documentation and decision records are updated when warranted;
- unrelated files and future-phase scaffolding are not included;
- rollback or safe recovery is understood.

### 33.1 Maturity Labels

A capability's label states what proved it, not how complete it feels. The
levels are defined in [ADR 2](docs/decisions/0002-guest-execution-verification-levels.md).

| Label | Meaning |
| --- | --- |
| **not started** | No implementation exists |
| **CI-proven** | Logic verified by tests that run on every push |
| **component-proven** | Additionally exercised against synthetic fixtures on a Windows runner |
| **lab-proven** | Additionally exercised end to end against a real disposable guest |
| **implemented; lab validation pending** | Code exists and is CI-proven or component-proven, but the behavior that needs a real guest has never been observed |

The last label is the one that carries weight. Transfer, restart, and
post-restart validation cannot be proven by any test that does not move bytes
into a machine, and describing them as working on the strength of a passing
configuration check would be false.

## 34. Agent Operating Model

Act as a senior engineering partner. Do not assume missing implementation exists and do not convert proposals into facts.

Label important statements as needed:

- **OBSERVED** — directly confirmed in repository content or tool output;
- **INFERRED** — strongly suggested but not confirmed;
- **PROPOSED** — a recommended design or change;
- **DEFERRED** — intentionally outside the current increment;
- **BLOCKED** — cannot proceed safely without missing authority, access, or a consequential decision.

For each meaningful task:

1. inspect current files, history, and uncommitted changes;
2. preserve user-authored work and avoid unrelated edits;
3. restate the bounded objective and affected responsibility;
4. identify security, lifecycle, and compatibility implications;
5. implement the smallest coherent change;
6. run the least expensive relevant checks first;
7. inspect the final diff for scope creep and private information;
8. report what changed, what was verified, and what remains deferred.

Ask for direction before making a choice that materially changes scope, trust boundaries, platform ownership, or destructive behavior. Routine implementation details within an accepted increment do not require repeated confirmation.

## 35. Current Starting Point

Begin every new handoff by inspecting the repository rather than assuming it is empty or complete.

Report:

1. current files and implemented capabilities;
2. uncommitted work that must be preserved;
3. gaps relative to the earliest active roadmap increment;
4. the smallest sensible next change;
5. the validation that will prove that change.

Until repository evidence establishes otherwise, prioritize the foundation, manifest contract, source qualification, and integrity path before Terraform, MCS, Intune, promotion, or lifecycle automation.

## 36. Open Decisions

Keep these as explicit decisions until implementation evidence or requirements resolve them:

- ~~base-image strategy: constructing from installation media versus consuming an
  existing image source~~ resolved by [ADR 6](docs/decisions/0006-base-image-from-installation-media.md):
  builds construct from installation media;
- artifact publication and reference-resolution mechanism, including whether
  Content Library is used;
- ~~how an image-build result enters the evidence contract~~ resolved by
  [ADR 7](docs/decisions/0007-image-identity-and-provenance.md): a new
  `evidence-envelope-3`, not an edit to version 2;
- package-source adapter and retention expectations;
- ~~canonical package-manifest serialization and minimum fields~~ resolved by [ADR 1](docs/decisions/0001-package-manifest-serialization.md);
- ~~image identity and versioning convention~~ resolved by
  [ADR 7](docs/decisions/0007-image-identity-and-provenance.md): `recipeDigest`
  for the inputs, `runId` for the execution, and the vSphere managed object
  reference for the artifact, all three bound in provenance;
- evidence schema and durable evidence store;
- CI implementation and approval mechanism;
- Packer runner model and secret-injection mechanism;
- Terraform backend and state boundaries;
- vSphere and Citrix provider/module boundaries;
- canary success criteria and timeouts;
- Intune query and validation mechanism;
- artifact retention, rollback window, and retirement policy;
- reconciliation frequency and automated-remediation limits.

The base-image decision was load-bearing, and settling it in
[ADR 6](docs/decisions/0006-base-image-from-installation-media.md) makes media
qualification (section 8.8), the media artifact class (section 10), and the
`sources/windows/` and `unattended/` paths (section 29) real rather than
proposed. The answer-file path carries a credential requirement, so it arrives
with a secret-handling constraint rather than as an ordinary build input.

Publication and reference resolution stay open. Increment 3 needs enough
identity and provenance to name and preserve a candidate; it does not need a
publication mechanism, and choosing one early would settle that decision the way
an early builder choice would have settled this one.

Do not hide unresolved decisions inside code defaults. Document assumptions, choose reversible options for early increments, and create a decision record when a choice becomes durable.

## 37. North Star

The repository should evolve into a clear reference implementation of this chain:

```text
Pinned source definitions
  -> verified Windows image build
  -> immutable image identity
  -> declarative canary provisioning
  -> evidence-based validation
  -> explicit promotion
  -> observable lifecycle reconciliation
```

Optimize for trust, clarity, and repeatability. Complexity is justified only when it protects a real requirement or removes demonstrated operational risk.
