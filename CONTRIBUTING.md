# Contributing

This repository is a public reference implementation built in small, verifiable
increments. The bar for a change is not "it works" — it is "a future engineer
can tell what it does, why it exists, and how it fails."

## Before you change anything

1. Inspect the repository, current branch, and working tree. Do not assume a
   component exists because [Agent_Handoff.md](Agent_Handoff.md) describes it.
2. Identify what is **observed** versus what is **proposed**. See the labels in
   [docs/glossary.md](docs/glossary.md).
3. Select the smallest increment that advances the target architecture.
4. Decide how the increment will be validated before writing it.
5. Do not scaffold for later phases. Empty directories and unused abstractions
   are not progress.

## Public repository boundary

Nothing in this repository may contain names identifying individuals,
affiliations, or organization-specific identifiers belonging to a non-public
context; non-public repository names or links; internal hostnames, addresses, account or
tenant identifiers, or network topology; credentials, certificates, tokens, or
private keys; proprietary code, scripts, installer binaries, or documents;
non-public ticket or incident data; or any value copied from a non-public
source.

Naming a technology vendor or product is expected; the stack cannot be described
otherwise. What must not appear is any identity, affiliation, or
organization-specific identifier belonging to a non-public context.

If potentially non-public information reaches you during a task, do not
reproduce it here. Replace it with an obviously fictional placeholder and say
plainly that you substituted it.

### Before you commit

The automated checks find structural values -- addresses, hostnames, key
material. The categories that matter most here are semantic, and no scanner will
find them. Read the complete diff and ask:

1. Could this be derived independently from public vendor documentation and
   general engineering knowledge?
2. Does it make complete sense to a reader with no context beyond this
   repository?
3. Are all identifiers, example values, topologies, and workflows generic?
4. Would it still be appropriate if quoted without surrounding context?

If any answer is uncertain, generalize the material further before committing.

Naming conventions, exact scale, deployment structure, and approval processes
are as revealing as a hostname, and survive the removal of every name around
them. Section 2.1 of [Agent_Handoff.md](Agent_Handoff.md) classifies what is
publishable.

The automated checks are a floor beneath this review, not a substitute for it.

Two habits make this durable:

- Keep organization-specific words in an untracked
  `.public-boundary-denylist`, never in a committed file.
- Enable the local hooks: `git config core.hooksPath scripts/hooks`. They check
  staged content and the commit message before anything leaves your machine.
  CI only reports a breach after it is already public.

## Validation

Run the cheapest relevant checks first, and all of these before opening a pull
request:

```bash
scripts/ci/check-public-boundary.sh
```

```bash
tests/test-public-boundary.sh
```

```bash
npx --yes markdownlint-cli2@0.23.2 "**/*.md"
```

```bash
shellcheck scripts/ci/*.sh scripts/hooks/* tests/*.sh
```

```bash
pwsh -NoProfile -Command "Invoke-Pester -Path source-qualification/tests -Output Detailed"
```

```bash
pwsh -NoProfile -Command "'./source-qualification','./scripts/ci','./packer/scripts' | ForEach-Object { Invoke-ScriptAnalyzer -Path \$_ -Recurse -Severity Error,Warning }"
```

```bash
packer fmt -check -recursive packer/harness packer/builds
```

The build configuration declares the vSphere plugin, so install it once before
running the builder tests; without it `packer validate` fails on a missing
plugin rather than on anything being tested:

```bash
packer init packer/builds
```

A lab scenario needs a disposable Windows target and is never run by CI:

```bash
pwsh ./scripts/ci/Invoke-LabScenario.ps1 -Scenario positive -ManifestPath <manifest> -SourceRoot <dir> -VarFile packer/harness/lab.auto.pkrvars.hcl
```

`shellcheck` and `pwsh` each need a local install:

```bash
brew install shellcheck powershell
```

The PowerShell checks additionally need two modules from the gallery:

```bash
pwsh -NoProfile -Command "Install-Module Pester,PSScriptAnalyzer -Scope CurrentUser -Force"
```

CI pins those modules to exact versions; a local install takes the current
release, so a finding may appear in CI that did not appear locally. The
remaining checks need only `git` and `npx`.

Secret scanning is gated by the CI **Secret scan** job, not by a local run. If
you have `gitleaks` installed, running it first is faster feedback:

```bash
gitleaks git -v --redact .
```

That command is optional. The CI job is the gate that must pass.

The same checks run in CI, which triggers on pushes to `main` and on pull
requests. A feature branch pushed on its own gets no run, so a branch is
validated by opening a pull request rather than by waiting. A green run on a
descendant commit confirms its ancestors; do not create empty commits to
provoke a run against a particular SHA.

A stage is added to CI only when the repository
contains the responsibility it validates — do not add a Packer or Terraform job
before there is a Packer or Terraform file to check.

### The scanner has no suppression mechanism, on purpose

A per-line exception marker was proposed and rejected. It becomes a committed
bypass: it does not work naturally inside JSON, and a marker suppressing one
finding on a line also suppresses a genuine prohibited value sitting beside it.

Two false positives are known and expected to recur: a four-component file
version reads as an address literal, and a JSON-escaped Windows path reads as a
UNC prefix. Neither is a reason to weaken the scanner. Runtime-generated evidence
is not tracked content, and bundle paths are relative, so most of this never
reaches a committed file. Where an example collides, choose a different example.

If a tracked literal ever proves genuinely unavoidable, the order is:

1. make a narrow rule-specific correction — for example, distinguishing a
   JSON-escaped drive path from a UNC prefix — and keep the mixed-value
   regression tests that prove a prohibited value beside a permitted one is still
   reported;
2. only as a last resort, add a sidecar exception keyed to an exact repository
   path, rule, line, exact-match digest of the line, and a written rationale;
3. never accept globs, stale entries, exceptions to the secret or denylist rules,
   or suppression of other matches on the same line;
4. have the pre-commit hook evaluate the **staged** sidecar rather than the
   working-tree copy, or the exception file becomes its own bypass.

### `Test-Json` does not enforce `if`/`then`

Verified against the pinned runtime: a draft-07 conditional written into a
schema validates every document, including the ones it appears to forbid. A rule
placed there reads like a constraint and enforces nothing, which is worse than
having no rule, because a reviewer stops looking for it elsewhere.

Rules coupling two fields -- "this may be present only when that has a
particular value" -- therefore live in a semantic validator beside the schema,
with tests that supply the forbidden combination. Do not move them into a schema
without first proving the runtime enforces the construct.

If you change `scripts/ci/check-public-boundary.sh`, add a case to
`tests/test-public-boundary.sh` that fails before your change and passes after
it. A scanner without tests reports "passed" just as confidently when it is
broken. The same applies to the manifest schema: a schema demonstrated only to
accept valid input has not been tested, so every rule needs a case proving it
rejects.

## Engineering standards

Full standards are in [Agent_Handoff.md](Agent_Handoff.md) section 31. The
recurring ones:

- **Definitions declare, scripts execute.** Keep imperative work bounded and out
  of declarative files.
- **Inputs are pinned.** Exact versions and source references. No `latest`, no
  wildcards, no discovery.
- **Integrity fails closed.** A missing, unreadable, or mismatched input stops
  the build. Never compute a hash at runtime and treat it as the expected value.
- **Artifacts are immutable.** A content change produces a new build and a new
  identity, never an edit in place.
- **Evidence is an output.** Every consequential stage emits enough data to
  explain its result, with secrets redacted.
- **Secrets enter at runtime.** Provide `.example` files with placeholders and
  document required secret names without values.

## Commits and pull requests

- Keep a change to one responsibility. Unrelated edits belong in their own
  commit.
- Write commit messages that explain why, not just what.
- Inspect the final diff for scope creep and for private information before
  committing.
- In the pull request, state what changed, what you verified, and what you
  deliberately left out.

## Decision records

Create an architecture decision record in `docs/decisions/` when a choice
changes a cross-domain contract, establishes a security or trust boundary,
selects a state or lifecycle boundary, introduces a major dependency, is costly
to reverse, or rejects a plausible alternative for a durable reason.

Do not create one for a function name, a folder spelling, or a logging string.
The threshold is whether a future engineer would reasonably ask, "why this
instead of the obvious alternative?"

## When to stop and ask

Ask before making a choice that materially changes scope, a trust boundary,
platform ownership, or destructive behavior. Routine implementation details
inside an accepted increment do not need confirmation.
