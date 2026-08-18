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

## 2. Public Repository Boundary

This is a generic, public reference implementation.

Repository content must not include:

- names of people, employers, clients, business units, teams, or private projects;
- private repository names or links;
- internal hostnames, domains, IP addresses, account identifiers, tenant identifiers, or network topology;
- credentials, secrets, certificates, tokens, or private keys;
- proprietary source code, scripts, installer binaries, documents, screenshots, or architecture artifacts;
- private ticket numbers, change records, incident details, or operational data;
- values copied from a non-public environment, even when they appear harmless.

Use neutral language, fictional identifiers, placeholder addresses, `.example` files, and synthetic test data. Examples should describe only the technologies and architecture patterns required to understand the solution.

If potentially private information is supplied during a task, do not reproduce it in the repository. Replace it with an obviously fictional placeholder and call out the substitution.

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
- embedding private environment details into examples.

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
|---|---|---|
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

## 11. Package Manifest Contract

One manifest normally describes the ordered software recipe for one image baseline.

Illustrative YAML:

```yaml
schemaVersion: 1
packages:
  - id: example-agent
    version: "1.2.3"
    source: "file://packages/example-agent/1.2.3/installer.msi"
    sha256: "<64-character-lowercase-hex-value>"
    installerType: msi
    installArgs:
      - "/qn"
      - "/norestart"
    order: 20
    required: true
    validation:
      type: fileVersion
      path: "C:\\Program Files\\Example Agent\\agent.exe"
      expectedVersion: "1.2.3"
```

Start with only fields required by implemented behavior. Likely core fields are:

- schema version;
- package ID;
- package version;
- exact source reference;
- expected SHA-256;
- installer type;
- install arguments represented safely as an array;
- install order;
- required/optional status;
- a bounded validation definition.

The manifest is an image recipe. It must not acquire endpoint-deployment concepts such as assignments, schedules, audience targeting, package search, update channels, or general dependency resolution.

Treat install arguments as untrusted data. Avoid command-string concatenation and use explicit process argument handling.

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
2. Validate its schema and semantic constraints.
3. Sort packages deterministically.
4. Resolve each exact source reference.
5. Copy the package into unique temporary host staging.
6. Calculate the host SHA-256 and compare it with the manifest.
7. Transfer only verified content through Packer.
8. Calculate the guest SHA-256 and compare it with the same expected value.
9. Execute the installer with explicit arguments.
10. Normalize the process result and restart requirement.
11. Validate installed state using a package-appropriate check.
12. Record a structured package result with secrets redacted.
13. Continue according to required/optional failure policy.
14. Aggregate the package results.
15. Remove guest staging.
16. Remove host staging.
17. Export durable evidence outside temporary locations.

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

Intune participation is deliberately bounded. The image build should prepare only prerequisites that genuinely belong in the base image. Runtime validation may confirm:

- expected enrollment state;
- device identity correlation;
- receipt of required policy;
- health of required management services;
- compliance or readiness signals that can be queried safely.

Do not duplicate Intune policy in Packer or Terraform. Do not turn this repository into a general Intune configuration repository unless the scope is explicitly changed.

## 22. Promotion, Rollback, and Retirement

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
- sanitized logs and failure messages;
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

Use this sequence as the strategic roadmap:

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

- Packer-controlled transfer;
- guest hash re-verification;
- bounded MSI/EXE execution;
- post-install validation;
- restart signaling and cleanup;
- package evidence aggregation.

### Increment 3: Image build and sealing

- complete Packer template;
- base-image and tool version pinning;
- pre-generalization checks;
- generalization, shutdown, and vSphere sealing;
- immutable identity and provenance.

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
- secrets and private identifiers are absent;
- evidence needed to explain the result is produced;
- documentation and decision records are updated when warranted;
- unrelated files and future-phase scaffolding are not included;
- rollback or safe recovery is understood.

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

- package-source adapter and retention expectations;
- canonical package-manifest serialization and minimum fields;
- image identity and versioning convention;
- evidence schema and durable evidence store;
- CI implementation and approval mechanism;
- Packer runner model and secret-injection mechanism;
- Terraform backend and state boundaries;
- vSphere and Citrix provider/module boundaries;
- canary success criteria and timeouts;
- Intune query and validation mechanism;
- artifact retention, rollback window, and retirement policy;
- reconciliation frequency and automated-remediation limits.

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
