# 5. Evidence versioning and run identity

## Status

Accepted; planned for Increment 2. Nothing in this record is implemented yet.

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

Renaming a field and adding another is a breaking change to anything parsing
evidence, so the evidence shape moves to **`ResultSchemaVersion = 2`**. The
Increment 1 shape is retrospectively version 1. Tests assert the literal value,
not merely that the field is present: a test checking presence passes against a
document still emitting the old number.

### One run identity, supplied by the parent

A single run identifier flows from the orchestrator through host qualification,
transfer, and guest provisioning. Stages accept it; they do not each invent one.
Increment 1 generated its own, which was correct when qualification was the whole
run and is not correct now.

The identifier is a **canonical UUID** and is validated before use, against
`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, lowercase.
Anything else is rejected outright.

This is a confinement rule, not a formatting preference. The run identifier
names staging directories on both host and guest, so an arbitrary caller-supplied
string is a path-traversal vector reaching a directory that is later deleted
recursively. Validation happens before the value is interpolated into any path.

### What evidence may not contain

Extending the bounded-code rule from Increment 1, evidence never carries
installer arguments, command lines, source paths, guest paths, environment
values, or raw exception text.

Arguments are the newly tempting one, because a failed install is exactly when
someone wants to see the command. They are manifest-supplied and may encode
install locations, property values, or a credential a manifest author should not
have put there but might.

They are therefore excluded from **every** log, not diverted into a restricted
one. A restricted log is still a file on a build host that gets collected,
archived, and attached to a ticket, and "restricted" is a property of intent
rather than of the artifact. What may be logged about an installer invocation is
bounded metadata only:

- package identifier and version;
- argument or property **count**, never contents;
- outcome and reason code;
- duration and exit code.

Reproducing a failure means reading the manifest, which is version controlled and
already subject to the content policy. Nothing is lost that the manifest does not
already provide.

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
  `ResultSchemaVersion`, set to 2, and `ManifestSchemaVersion` is added. Evidence
  is not a frozen contract the way the manifest schema is, but this breaks
  anything parsing it, so it is recorded here.
- `Invoke-SourceQualification` takes an optional run identifier, validates it,
  and generates one only when called standalone.
- Diagnosing a failed install means reading the manifest and the bounded
  metadata. No log holds the arguments, by design.

## Validation implications

Tests assert the literal `ResultSchemaVersion = 2`, the presence of
`ManifestSchemaVersion`, and the absence of any field named `SchemaVersion`, so
the ambiguous name cannot return and a stale value cannot pass as a fresh one.

The run identifier needs rejection cases: a non-canonical string, an uppercase
UUID, and a value containing path separators or dot segments, each refused before
any directory is created.

The exclusion rule needs the same treatment the source-root leak eventually got:
assert against the failure path that would actually carry an argument, with the
document parsed rather than pattern-matched as text. A test written against the
wrong failure passes on a defective implementation.
