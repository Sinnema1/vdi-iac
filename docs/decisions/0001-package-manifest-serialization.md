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

Manifests are JSON, validated in two stages:

1. **Structure** — a committed JSON Schema, `contracts/package-manifest.schema.json`,
   checked with `Test-Json -SchemaFile`. It is draft-07 and sets
   `additionalProperties: false` at both levels.
2. **Semantics** — checks a schema cannot express, implemented in PowerShell:
   duplicate identifiers, duplicate ordering keys, and source resolvability.

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
- Adding a field is a schema change. Backward-compatible additions keep
  `schemaVersion` at 1; anything else increments it.
- `additionalProperties: false` means Increment 2 must extend the schema in the
  same change that consumes the new fields, which is the intended coupling.

## Validation implications

The schema is exercised by regression tests covering both acceptance and
rejection: unknown fields at either level, an empty package list, a wrong schema
version, malformed or uppercase SHA-256 values, wildcard versions, non-file
source schemes, path traversal in a source reference, missing required fields,
and out-of-range ordering keys.

A schema that has only ever been shown to accept valid input has not been
tested. Every rule above must be shown to reject.
