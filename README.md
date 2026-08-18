# vdi-iac

A public reference implementation for deterministic Windows virtual desktop
image creation, provisioning, validation, promotion, and lifecycle management
using infrastructure-as-code practices.

The goal is not maximum automation. It is a solution that is repeatable,
deterministic, testable, auditable, maintainable, secure, and understandable.

## Status

**Increment 0 — repository foundation.** No image-build, provisioning, or
lifecycle capability is implemented yet.

This repository documents a target architecture and is being built toward it in
small increments. Read [Agent_Handoff.md](Agent_Handoff.md) as the statement of
intended direction, not as evidence that a component exists. Where the two
disagree, the repository is correct and the document is aspirational.

What exists today:

| Area | State |
| --- | --- |
| Solution charter and architecture direction | documented |
| Agent operating rules and glossary | documented |
| Public-boundary, secret, Markdown, and shell checks | configured; pending first successful CI run |
| Package manifest contract | not started |
| Source qualification and integrity verification | not started |
| Packer image construction and sealing | not started |
| Terraform and Citrix MCS provisioning | not started |
| Promotion, reconciliation, and retirement | not started |

The delivery sequence is defined in
[Agent_Handoff.md](Agent_Handoff.md) section 32. The next increment is the
package manifest contract and source integrity path.

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
| [continue-config.md](continue-config.md) | Continue model routing, plan-mode workflow, context and slash-command guidance |

## Public repository boundary

This is a public repository. It must not contain names of people, employers,
clients, business units, or private projects; internal hostnames, addresses,
account or tenant identifiers, or network topology; credentials or private
keys; proprietary code or documents; or values copied from a non-public
environment, even when they appear harmless.

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

`gitleaks` is not required to be installed for the other checks to run. Install
it locally with `brew install gitleaks`, or rely on the CI job. Likewise
`brew install shellcheck`. Note that
`gitleaks detect` is the deprecated spelling; `gitleaks git` and `gitleaks dir`
are current.

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
literals, internal hostnames, UNC paths, private keys. It intentionally
contains no organization-specific words, because committing that list to a
public repository would republish the strings it is meant to exclude.

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
