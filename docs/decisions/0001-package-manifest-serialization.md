# 1. Package manifest serialization and validation

## Status

Accepted.

## Context

Section 11 of the charter describes a package manifest as the ordered software
recipe for one image baseline, and section 36 recorded its canonical
serialization as unresolved. Increment 1 implements the contract, so the choice
can no longer be deferred without hiding it inside a code default.

The manifest is machine-consumed at build time and hand-authored. It must be
validated before expensive build work begins, and validation must fail closed:
an unparseable or non-conforming manifest stops the build rather than being
partially honoured.

The host-side qualification code is PowerShell, which keeps one language across
host and guest work.

## Decision

Manifests are JSON, validated in two stages. A third class of check is
deliberately *not* manifest validation, and the boundary between them is the
part worth stating precisely.

**1. Structure — the committed JSON Schema**, `contracts/package-manifest.schema.json`,
checked with `Test-Json -SchemaFile`. Draft-07, `additionalProperties: false` at
both levels. It enforces everything decidable from the manifest text alone:

- field presence, types, and value patterns;
- exact versions — ranges, wildcards, a trailing `.x` series suffix, and moving
  references such as `latest` are rejected, case-insensitively;
- source references confined to the file scheme, with dot segments rejected, so
  a traversing reference is refused when the manifest is validated rather than
  when it is resolved.

**2. Semantics — PowerShell**, for what a schema cannot express because it spans
entries rather than describing one:

- duplicate package identifiers, which make a result set ambiguous;
- duplicate ordering keys, which make the sequence non-deterministic.

**3. Runtime availability — not manifest validation.** Whether a source exists,
is readable, stays inside the source root once links are considered, and matches
its expected hash are properties of the filesystem at run time, not of the
manifest. They belong to qualification and are reported as package outcomes with
bounded reason codes. A manifest is valid or invalid independently of whether the
machine reading it can currently see the files.

Schema version 1 carries only the fields Increment 1 consumes: `schemaVersion`,
and per package `id`, `version`, `source`, `sha256`, `order`, and `required`.
Fields belonging to later increments are absent, and `additionalProperties:
false` means a manifest carrying them is rejected rather than silently accepted.

## Alternatives considered

**YAML.** Matches the charter's original illustration, permits comments, and
produces more readable diffs. Rejected because PowerShell has no native YAML
parser: it would add an external module to every host that qualifies a manifest
and to CI, for a file that is written rarely and read by machines. The comment
loss is real and is the main cost of this decision.

**YAML authored, JSON generated.** Retains comments and gains schema tooling,
at the cost of two representations of one contract and a conversion step. The
generated artifact can be edited directly, and then the two disagree. Rejected
as more machinery than the problem justifies.

**PowerShell validation with no schema file.** Fewer moving parts. Rejected
because the contract would exist only as code, leaving no declarative artifact
for another implementation to validate against.

## Consequences

- No external module is needed to read or validate a manifest.
- The contract is publishable and consumable independently of this repository's
  PowerShell code.
- Manifests cannot carry comments. Anything explanatory belongs in the document
  that describes the baseline, not in the manifest.
- `additionalProperties: false` means Increment 2 must extend the schema in the
  same change that consumes the new fields, which is the intended coupling.

### Compatibility, defined from the consumer's side

Compatibility is a property of a *validator*, not of a document. Because
`additionalProperties: false` applies at both levels, a validator holding schema
version 1 rejects any manifest carrying a field version 1 does not name --
including a field that is optional to the producer. There is therefore no such
thing as a backward-compatible field addition here.

The rule that follows:

| Change | Effect on a v1 validator | Version |
| --- | --- | --- |
| Adding any field, optional or not | Rejects the document | Increment |
| Removing a field, or narrowing a value pattern | Accepts documents it should now refuse | Increment |
| Widening a value pattern within an existing field | Accepts everything v1 accepted | May stay 1 |
| Editing a description | No effect on validation | Stays 1 |

Increment 2 introduces installer type, install arguments, and the bounded
validation definition. Every one of those is a field addition, so **Increment 2
publishes schema version 2**. A version 1 manifest remains valid against the
version 1 schema; a producer that emits the new fields must declare version 2.

This is the cost of `additionalProperties: false`, and it is the intended
trade: an unrecognized field is a mistake worth failing on, and paying for that
with an explicit version bump is preferable to accepting fields nothing reads.

## Validation implications

Regression tests cover rejection, not only acceptance: unknown fields at either
level, an empty package list, a wrong schema version, malformed or uppercase
SHA-256 values, moving version references in several cases, version ranges and
wildcards, dot segments in a source reference, non-file schemes, missing
required fields, out-of-range ordering keys, and both semantic rules.

A schema that has only ever been shown to accept valid input has not been
tested. Every rule above must be shown to reject.

CI validates every committed manifest with `Import-PackageManifest`, not with
`Test-Json` alone. A schema-only gate would pass a manifest carrying duplicate
identifiers or duplicate ordering keys, since neither is expressible in the
schema, and the fixed test against the example manifest does not generalize to
manifests added later.
