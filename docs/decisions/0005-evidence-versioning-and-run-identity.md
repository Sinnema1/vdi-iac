# 5. Evidence versioning and run identity

## Status

Accepted. Implemented by Increment 2.

## Context

The qualification result carries `SchemaVersion = 1`. With one schema in
existence that read unambiguously. Once manifest version 2 exists it stops
being readable: a result from a version 2 manifest would still say
`SchemaVersion = 1`, meaning the result format, while appearing to describe the
manifest.

Increment 2 also spans three stages -- host qualification, Packer orchestration,
guest provisioning -- each producing evidence. Without a shared identifier,
correlating them means matching on timestamps, which is guesswork the moment two
runs overlap.

## Decision

### Two versions, separately named

Evidence carries both, and neither is called `SchemaVersion`:

- `ResultSchemaVersion` — the shape of the evidence document itself;
- `ManifestSchemaVersion` — the version of the manifest the run consumed.

They move independently. A change to the evidence format does not imply a
manifest change, and the reverse.

### One run identity, supplied by the parent

A single run identifier flows from the orchestrator through host qualification,
transfer, and guest provisioning. Stages accept it; they do not each invent one.
Increment 1 generated its own, which was correct when qualification was the whole
run and is not correct now.

### What evidence may not contain

Extending the bounded-code rule from Increment 1, evidence never carries
installer arguments, command lines, source paths, guest paths, environment
values, or raw exception text.

Arguments are the newly tempting one, because a failed install is exactly when
someone wants to see the command. They are manifest-supplied and may encode
non-public detail such as install locations or property values, so they stay in
the restricted log and out of the published document.

## Alternatives considered

**Keep one `SchemaVersion` and infer the rest.** Rejected. It is the ambiguity
that prompted this record.

**Version evidence implicitly by repository revision.** Rejected. Evidence
outlives the checkout that produced it, and a consumer should not need the source
tree to parse a document.

**Let each stage generate its own identifier and correlate by timestamp.**
Rejected. It fails exactly when correlation matters most, under concurrent runs.

## Consequences

- The Increment 1 result shape changes: `SchemaVersion` becomes
  `ResultSchemaVersion`, and `ManifestSchemaVersion` is added. Evidence is not a
  frozen contract the way the manifest schema is, but the change is a break for
  anything parsing it, so it is recorded here.
- `Invoke-SourceQualification` takes an optional run identifier and generates one
  only when called standalone.
- Diagnosing a failed install needs the restricted log, not the evidence file, by
  design.

## Validation implications

A test asserts that evidence contains both version fields and no field named
`SchemaVersion`, so the ambiguous name cannot return.

The exclusion rule needs the same treatment the source-root leak eventually got:
assert against the failure path that would actually carry an argument, with the
document parsed rather than pattern-matched as text. A test written against the
wrong failure passes on a defective implementation.
