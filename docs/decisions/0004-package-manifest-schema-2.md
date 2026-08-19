# 4. Package manifest schema version 2

## Status

Accepted. Implemented by Increment 2.

## Context

Increment 2 executes installers and validates what they installed. That needs
fields version 1 does not have. Under ADR 1, adding a field changes the accepted
document set, so this is version 2, published as a new file. Version 1 is frozen
byte-for-byte; its SHA-256 is

```text
d05796232c677cb2c7b5c19e54fc02a75bf579d8dc1b33897f90e1eddfccb16d
```

The design pressure here is that a manifest is untrusted data which ends up
deciding what runs on a machine. Every field added is a field an attacker or a
careless author can populate.

## Decision

### Dispatch

Version 2 is a new file alongside version 1. Selection uses a **hard-coded map**
from declared version to schema path. A path is never constructed from the
declared value, and there is no fallback to the newest schema: an unrecognized
version is rejected. A manifest that validated against version 1 continues to
validate.

The frozen digest above is asserted by a test, so an accidental edit to version 1
fails rather than silently changing a supported contract.

### Installer

```json
"installer": {
  "kind": "msi",
  "arguments": ["ALLUSERS=1"],
  "timeoutSeconds": 1800,
  "restartPolicy": "allow-deferred"
}
```

- `kind` is `msi` or `exe` only, and must agree with the source extension;
- `arguments` is an array of tokens, never a command string. Tokens rejecting
  NUL, CR, LF, and empty values, and rejecting MSI switches the executor owns;
- `timeoutSeconds` is required and bounded, 60 to 7200;
- `restartPolicy` is `forbid` or `allow-deferred`. An installer-initiated
  immediate reboot is unsupported, because Packer owns the restart boundary.

MSI exit codes are fixed by the platform, so the contract states them rather
than letting a manifest redefine them: `0` is success, `3010` is success with a
deferred restart required, and `1641` is a **failure** because the installer
initiated a reboot outside Packer's control.

EXE packages have no common convention, so they declare theirs:

```json
"exitCodes": {
  "success": [0],
  "restartRequired": [3010]
}
```

Both arrays are bounded and unique, must be disjoint from each other, and may
never contain `1641`.

### Validation

A non-empty array, all-of semantics, at most eight checks, each with a stable
`id`. The allowlist is exactly:

- `file-exists`
- `file-version`
- `service-exists`

File checks take an allowlisted root plus a normalized relative path. Absolute
paths, dot segments, wildcards, and reparse escapes are rejected, reusing the
confinement rule Increment 1 already proved.

Not available, and not by oversight: arbitrary PowerShell, command or
health-command execution, manifest-supplied executable paths, regular
expressions or expression trees, and shell, environment-variable,
working-directory, retry, or secret fields. A package that cannot be validated
through this allowlist is unsupported by version 2. Widening the allowlist is
version 3.

Aggregation: any check failed makes the package `failed`; otherwise any
inconclusive check makes it `inconclusive`; only all-passed is `passed`. For a
required package, both `failed` and `inconclusive` fail the build.

## Alternatives considered

**A `command` validation kind.** Rejected. It is the single field that converts
a manifest from a description into a program, and every later constraint would
be an attempt to re-bound something already unbounded.

**Letting manifests define MSI exit codes.** Rejected. They are fixed by the
platform, and a manifest that redefines `1641` as success defeats Packer's
ownership of the restart boundary.

**A single `arguments` string.** Rejected on measured evidence, recorded in
ADR 2: joining tokens into a string and re-splitting them loses spaces and
quoting.

**Reusing version 1 with optional fields.** Not available. `additionalProperties`
is false, so version 1 rejects them outright.

## Consequences

- Two schema files exist, and the dispatcher is a contract of its own.
- Some real packages cannot be expressed in version 2. That is intended: the
  allowlist grows on evidence, through a new version.
- MSI and EXE take different paths through exit-code normalization, so both need
  their own coverage.

## Validation implications

Every rule above needs a case proving it rejects, not only that a valid manifest
passes. Specifically: an unknown declared version, a version 1 manifest still
validating, a kind that disagrees with its source extension, argument tokens
containing NUL or newlines, out-of-range timeouts, `1641` appearing in either
EXE array, overlapping success and restart arrays, an empty validation array,
more than eight checks, duplicate check ids, and each rejected file-path form.

The frozen version 1 digest is itself a test.
