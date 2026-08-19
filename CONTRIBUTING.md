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

Run the cheapest relevant checks first, and all of them before opening a pull
request:

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

The same checks run in CI. A stage is added to CI only when the repository
contains the responsibility it validates — do not add a Packer or Terraform job
before there is a Packer or Terraform file to check.

If you change `scripts/ci/check-public-boundary.sh`, add a case to
`tests/test-public-boundary.sh` that fails before your change and passes after
it. A scanner without tests reports "passed" just as confidently when it is
broken.

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
