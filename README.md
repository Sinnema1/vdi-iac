# vdi-iac

A public reference implementation for deterministic Windows virtual desktop
image creation, provisioning, validation, promotion, and lifecycle management
using infrastructure-as-code practices.

The goal is not maximum automation. It is a solution that is repeatable,
deterministic, testable, auditable, maintainable, secure, and understandable.

## Status

**Increment 1 complete. Package manifest schema version 1 is supported and
frozen. Increment 2 is implementation complete; lab validation pending** — the
guest provisioning path and its Packer harness exist and are CI-proven, but
transfer, installer execution, the restart boundary, and post-restart validation
have never run against a real Windows guest. No image is built or sealed yet.

 From this point, `contracts/package-manifest.schema.json` is
byte-for-byte immutable and any validation change publishes a new schema
version — see [ADR 1](docs/decisions/0001-package-manifest-serialization.md).

The host-side path is implemented: manifests are validated against a committed schema, sources are
resolved under a confined root, staged, and verified against their expected
SHA-256. No image is built and nothing is provisioned yet.

This repository documents a target architecture and is being built toward it in
small increments. Read [Agent_Handoff.md](Agent_Handoff.md) as the statement of
intended direction, not as evidence that a component exists. Where the two
disagree, the repository is correct and the document is aspirational.

What exists today:

| Area | State |
| --- | --- |
| Solution charter and architecture direction | documented |
| Agent operating rules and glossary | documented |
| Public-boundary, secret, Markdown, and shell checks | enforced in CI |
| Package manifest contract | version 1 supported and frozen; version 2 an implementation draft |
| Source qualification and integrity verification | host-side path implemented |
| Guest provisioning and transfer bundle | implemented; lab validation pending |
| Packer lab harness (null builder) | implemented; lab validation pending |
| Lab scenarios (positive, payload tamper, descriptor tamper) | defined and runnable; never executed |
| Packer image build and sealing | not started |
| Packer image construction and sealing | not started |
| Terraform and Citrix MCS provisioning | not started |
| Promotion, reconciliation, and retirement | not started |

The delivery sequence is defined in
[Agent_Handoff.md](Agent_Handoff.md) section 32. The next increment is 3, image
build and sealing: selecting a Windows source, building, generalizing, shutting
down, sealing, versioning, and establishing provenance for a candidate image.
**No candidate image has been built or sealed yet.**

## Intended architecture

The chain the repository is being built to demonstrate:

```text
Pinned source definitions
  -> verified Windows image build
  -> immutable image identity
  -> declarative canary provisioning
  -> evidence-based validation
  -> explicit promotion
  -> observable lifecycle reconciliation
```

Target technologies are Packer for Windows image construction, PowerShell for
guest configuration and validation, VMware vSphere as the virtualization
platform, Terraform for declarative infrastructure, Citrix Machine Creation
Services for catalog provisioning, and Microsoft Intune for bounded
post-provision validation.

## Documentation

| Document | Purpose |
| --- | --- |
| [Agent_Handoff.md](Agent_Handoff.md) | Solution charter, architectural principles, lifecycle phases, ownership boundaries, delivery sequence |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to propose and validate a change |
| [docs/glossary.md](docs/glossary.md) | Architectural vocabulary used throughout |
| [docs/decisions/](docs/decisions/) | Architecture decision records |
| [contracts/](contracts/) | Machine-consumed schemas defining cross-domain boundaries |
| [continue-config.md](continue-config.md) | Continue model routing, plan-mode workflow, context and slash-command guidance |

## Public repository boundary

This is a public repository. It must not contain names identifying individuals,
affiliations, or organization-specific identifiers belonging to a non-public
context; internal hostnames, addresses, account or tenant identifiers, or
network topology; credentials or private keys; proprietary code or documents; or
values copied from any non-public source, even when they appear harmless.

Naming a technology vendor or product is expected; the stack cannot be described
otherwise. What must not appear is any identity, affiliation, or
organization-specific identifier belonging to a non-public context.

Beyond specific values, some categories reveal origin through their shape alone
— naming conventions, exact scale, deployment structure, and approval processes
among them. Section 2.1 of [Agent_Handoff.md](Agent_Handoff.md) classifies what
is publishable.

Use neutral language, fictional identifiers, placeholder addresses, `.example`
files, and synthetic test data. The full constraint is in
[Agent_Handoff.md](Agent_Handoff.md) section 2, and it is enforced by the checks
below.

## Validation

All checks run in CI on push and pull request. To run them locally:

```bash
scripts/ci/check-public-boundary.sh
```

```bash
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

```bash
gitleaks git -v --redact .
```

```bash
tests/test-public-boundary.sh
```

```bash
shellcheck scripts/ci/*.sh scripts/hooks/* tests/*.sh
```

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path source-qualification/tests -Output Detailed"
```

```bash
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path ./source-qualification -Recurse -Severity Error,Warning"
```

`pwsh` needs a local install (`brew install powershell`), and the two modules
come from the gallery:

```bash
pwsh -NoProfile -Command "Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser -Force"
```

`gitleaks` is optional locally — secret scanning is gated by the CI **Secret
scan** job. Install it with `brew install gitleaks` if you want the faster
feedback; note that `gitleaks detect` is the deprecated spelling, and `gitleaks
git` and `gitleaks dir` are current. `shellcheck` also needs a local install
(`brew install shellcheck`); the remaining checks need only `git` and `npx`.

### Local hooks

CI reports a breach only after the content has been pushed, by which point it is
already public. Two hooks move the check earlier:

```bash
git config core.hooksPath scripts/hooks
```

| Hook | Covers | Why CI cannot |
| --- | --- | --- |
| `pre-commit` | Staged file content | CI runs after the push, not before |
| `commit-msg` | The commit message | gitleaks scans blobs; the boundary check scans files. Neither reads messages |

Both apply your local denylist, and both can be bypassed with
`git commit --no-verify` when a finding is genuinely a false positive.

This is per-clone configuration — `core.hooksPath` is not carried in the
repository, so every clone must set it.

### Local denylist

The boundary check enforces structural rules — email addresses, address
literals, internal hostnames, UNC paths, private keys — against both file
contents and the paths themselves, since a directory name is published content
too. It intentionally contains no organization-specific words, because
committing that list to a public repository would republish the strings it is
meant to exclude.

To additionally block specific words in your working copy, create an untracked
denylist:

```bash
printf '%s\n' 'a-word-that-must-not-appear' > .public-boundary-denylist
```

The path is git-ignored. The check applies it when present and reports which
mode it ran in.

## License

Not yet selected. Until a license is added, no permissions are granted beyond
viewing.
