# Architectural Glossary

Shared vocabulary for this repository. Terms are defined as this repository uses
them, which is sometimes narrower than general industry usage.

## Evidence labels

Used when reporting on repository state, in commit messages, pull requests, and
agent output.

| Label | Meaning |
| --- | --- |
| **OBSERVED** | Directly confirmed in repository content or tool output |
| **INFERRED** | Strongly suggested but not confirmed |
| **PROPOSED** | A recommended design or change, not yet implemented |
| **DEFERRED** | Intentionally outside the current increment |
| **BLOCKED** | Cannot proceed safely without missing authority, access, or a consequential decision |

The distinction that matters most: a description in
[Agent_Handoff.md](../Agent_Handoff.md) is PROPOSED, not OBSERVED. The document
describes a target; only the repository proves what exists.

## Image lifecycle

| Term | Meaning |
| --- | --- |
| **Base image** | The starting operating-system image a build begins from |
| **Candidate image** | A sealed image produced by a build, not yet validated or approved |
| **Sealing** | Capturing the shut-down, generalized build VM as an immutable vSphere artifact |
| **Generalization** | Removing machine-specific identity from the guest so it can be cloned |
| **Image identity** | A durable identifier that maps unambiguously to construction inputs, never a mutable display name |
| **Provenance** | The record linking an image to its source revision, manifest, packages, tool versions, and validation results |
| **Promotion** | An explicit decision to authorize an image for wider use, separate from building it |
| **Rollback** | Selecting a previously approved immutable image through the same orchestration path |
| **Retirement** | Destructive removal of a superseded artifact, requiring dependency checks and explicit targeting |

Lifecycle states:

```text
built -> validated -> canary -> approved -> promoted -> superseded -> retired
```

## Build and integrity

| Term | Meaning |
| --- | --- |
| **Manifest** | The ordered software recipe for one image baseline; an image recipe, not deployment policy |
| **Source qualification** | Resolving an exact package source, staging it host-side, and verifying it before the build |
| **Expected SHA-256** | A hash established in version control *before* runtime, used at both verification boundaries |
| **Host verification** | Hash check performed by the build execution context before transfer to the guest |
| **Guest verification** | Hash re-check performed inside the guest after transfer, against the same expected value |
| **Fail-closed** | A missing, unreadable, malformed, or mismatched input stops the build rather than continuing |
| **Pinning** | Exact versions and source references, replacing `latest`, wildcards, and discovery |
| **Staging** | Temporary storage of package content, removed after results are preserved |

Never calculate a hash at runtime and then treat that value as the expected
hash. That verifies only that a file equals itself.

## Validation

| Term | Meaning |
| --- | --- |
| **Material validation** | Confirming installed state, as distinct from an installer exit code of `0` |
| **Passed** | The expected state is observed |
| **Failed** | The expected state is not observed |
| **Inconclusive** | The check could not establish a result |
| **Canary** | A deliberately limited provisioning run used to validate a candidate before wider rollout |

For required packages, both `failed` and `inconclusive` fail the build unless
the contract explicitly defines safer behavior. Inconclusive validation blocks
promotion.

## Infrastructure and lifecycle

| Term | Meaning |
| --- | --- |
| **MCS** | Citrix Machine Creation Services, which provisions machine catalogs from a sealed image |
| **Machine catalog** | The Citrix construct grouping machines provisioned from one image reference |
| **State boundary** | The division of Terraform state, following lifecycle ownership and blast radius |
| **Drift** | Divergence between declared intent and observed platform state |
| **Reconciliation** | Comparing desired and observed state and classifying the difference |
| **Orphaned infrastructure** | Resources no longer described by any declaration |

Discovery of drift is not authorization to destroy or replace resources.

## Evidence and operations

| Term | Meaning |
| --- | --- |
| **Evidence** | Machine-readable output from a stage, sufficient to explain its result |
| **Run identifier** | The value correlating evidence across stages of one execution |
| **Redaction** | Removing secrets and sensitive runtime values before evidence is written |
| **Contract** | An explicit definition of inputs, outputs, ownership, validation, and failure behavior at a boundary |
| **Increment** | A bounded unit of delivery from the sequence in [Agent_Handoff.md](../Agent_Handoff.md) section 32 |
| **ADR** | Architecture decision record, stored in `docs/decisions/` |

## Architecture views

Levels used when documenting or discussing the solution. These describe
different views of the same system and should not be conflated with runtime
sequence, repository layout, delivery backlog, or state layout.

| Level | View | Purpose |
| --- | --- | --- |
| L0 | System context | Actors, external platforms, trust boundaries |
| L1 | End-to-end lifecycle | Major phases and promotion gates |
| L2 | Logical domains | Ownership and responsibility boundaries |
| L3 | Component interaction | Inputs, outputs, sequences, failure paths |
| L4 | Implementation | Files, modules, scripts, tests, pipeline jobs |
