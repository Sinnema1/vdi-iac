# 4. Package manifest schema version 2

## Status

Accepted; planned for Increment 2. Nothing in this record is implemented yet.

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

Stage 1 will add a test asserting the frozen digest, so an accidental edit to
version 1 fails rather than silently changing a supported contract. That guard
does not exist yet.

### Installer

MSI and EXE take different input shapes, because their argument conventions
differ and a single shape would have to be loose enough for both.

**MSI** supplies a property map, not tokens:

```json
"installer": {
  "kind": "msi",
  "properties": { "ALLUSERS": "1", "REBOOT": "ReallySuppress" },
  "timeoutSeconds": 1800,
  "restartPolicy": "allow-deferred"
}
```

The executor owns the command line entirely: it supplies the quiet and
no-restart switches and the log path, and appends `NAME=value` for each
property. A manifest cannot pass a switch at all, which is stricter and simpler
than trying to enumerate the switches it may not pass.

- property names match `^[A-Z][A-Z0-9_]{0,63}$`;
- property values are strings, 1 to 512 characters, rejecting NUL, CR, and LF;
- at most 32 properties.

**EXE** has no common convention, so it supplies tokens and declares its codes:

```json
"installer": {
  "kind": "exe",
  "arguments": ["/quiet", "/norestart"],
  "timeoutSeconds": 1800,
  "restartPolicy": "allow-deferred",
  "exitCodes": { "success": [0], "restartRequired": [3010] }
}
```

- `arguments` holds 0 to 32 tokens, each 1 to 512 characters, rejecting NUL, CR,
  and LF, and passed individually rather than joined;
- `success` holds 1 to 8 codes; `restartRequired` holds 0 to 8;
- both are unique, disjoint from each other, and may never contain `1641`.

Common to both:

- `kind` is `msi` or `exe`, and must agree with the source file extension;
- `timeoutSeconds` is required, an integer from 60 to 7200;
- `restartPolicy` is `forbid` or `allow-deferred`.

MSI exit codes are fixed by the platform and stated by the contract rather than
declared per manifest: `0` is success, `3010` is success with a deferred restart
required, and `1641` is a **failure**, because the installer initiated a reboot
outside Packer's ownership of the restart boundary.

When `restartPolicy` is `forbid` and the installer reports a restart is
required, the package fails with reason code `restart_forbidden`. The result is
not silently downgraded to success.

### Restart placement

One restart, always, after the whole package batch, whether or not any package
asked for it. Post-restart validation therefore always runs on the same side of
the boundary.

A conditional restart would make the sequence depend on manifest content, so two
runs of the same build could validate in different machine states. The cost is
one reboot on builds that did not need it, which is a few minutes against a
determinism property worth more than that.

### Validation

A non-empty array, all-of semantics, 1 to 8 checks, each with a stable `id`
matching `^[a-z0-9]+(-[a-z0-9]+)*$` and unique within the package.

Every check names an allowlisted root rather than an absolute path. The
enumeration is closed:

| Root | Resolves to |
| --- | --- |
| `programFiles` | the 64-bit program files directory |
| `programFilesX86` | the 32-bit program files directory |
| `programData` | the machine-wide application data directory |
| `windows` | the Windows directory |
| `system32` | the 64-bit system directory |

`relativePath` is 1 to 260 characters and rejects absolute paths, drive letters,
leading separators, dot segments, wildcards, and any component resolving through
a reparse point, reusing the confinement rule Increment 1 proved.

The three kinds, in full:

```json
{ "id": "runtime-present", "kind": "file-exists",
  "root": "programFiles", "relativePath": "Example/Runtime/runtime.exe" }
```

```json
{ "id": "runtime-version", "kind": "file-version",
  "root": "programFiles", "relativePath": "Example/Runtime/runtime.exe",
  "versionField": "file", "expectedVersion": "4.2.1.4096" }
```

```json
{ "id": "agent-service", "kind": "service-exists",
  "serviceName": "ExampleAgent" }
```

- `versionField` is required, `file` or `product`. They differ routinely, and a
  default would silently pick one;
- `expectedVersion` is compared as equality over four numeric components, each
  0 to 65535, with absent components read as `0`. So `7.0.1024` and `7.0.1024.0`
  are equal. Ordering comparisons are not supported: a build pins an exact
  version, so "at least" has no meaning here;
- `serviceName` is the service key name, never the display name, and matches
  `^[A-Za-z0-9_.-]{1,80}$`. Display names are localized and not unique.

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

**Token arrays for MSI as well as EXE.** Rejected. It would require enumerating
the switches a manifest may not pass, and any such list is a denylist that ages
badly. A property map cannot express a switch at all.

**A conditional restart.** Rejected. It makes the machine state at validation
time depend on manifest content.

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
passes. Specifically: an unknown declared version; a version 1 manifest still
validating; a kind disagreeing with its source extension; a property name or
value outside its pattern or bounds; more than 32 properties or tokens; a token
containing NUL, CR, or LF; out-of-range timeouts; `1641` in either EXE array;
overlapping success and restart arrays; arrays outside their bounds; an empty or
over-long validation array; duplicate or malformed check ids; a root outside the
enumeration; each rejected `relativePath` form; a missing `versionField`; a
malformed `serviceName`; and `restart_forbidden` when a `forbid` package reports
a restart is required.

Version comparison needs its own cases: `7.0.1024` equal to `7.0.1024.0`, and
unequal to `7.0.1024.1`.

Reparse confinement cannot be proven by path-string tests. It needs a Windows
component test creating a real junction or symbolic link, as ADR 2 requires for
Level 2.

The frozen version 1 digest will be asserted by a stage-1 test.
