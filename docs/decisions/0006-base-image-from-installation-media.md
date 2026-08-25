# 6. Base image from installation media

## Status

Accepted. Implementation begins in Increment 3. No candidate image has been
built or sealed.

## Context

Section 36 held this open deliberately, because it is load-bearing: it decides
whether media qualification, the media artifact class, and the source and
answer-file paths exist at all. An implementation choice made early would have
settled it silently, which is the outcome that section warned against.

Two paths were available.

**Construct from installation media.** The build begins from vendor-published
operating-system media, qualified against a separately published checksum, and
installs Windows unattended before any package is applied.

**Consume an existing image source.** The build begins from a template or
virtual machine that already exists, and customizes it.

The chain this repository exists to demonstrate begins with *pinned source
definitions* and ends with an image whose provenance can be stated. The second
path breaks that chain at the first link. Whatever is already in the template is
inherited, and nothing in the pipeline can say where it came from, what version
it was, or what has been changed by hand since it was created. Every downstream
guarantee -- deterministic construction, immutable identity, provenance linking
an image to its inputs -- would then rest on an input the system cannot describe.

The distinction is not theoretical. "What is in this image?" is the question the
whole lifecycle is built to answer, and a template-derived image answers it with
"whatever was in the template."

## Decision

**Builds construct the image from installation media.**

Consequences that follow directly:

- **Media is qualified, not assumed.** Section 8.8 stops being PROPOSED. A media
  reference resolves to an exact artifact, verified against a checksum published
  independently of the artifact itself. A hash computed from the downloaded file
  at runtime verifies only that the file equals itself, which is the failure this
  repository names explicitly in its glossary.
- **Media is a distinct artifact class.** It is not a manifest entry. It does not
  travel the guest package-staging path. It is presented to the build VM by other
  means, and it is verified at acquisition and again at each boundary it crosses.
- **Installation is unattended and declarative.** An answer file drives Windows
  setup. It is a build input like any other: version-controlled, reviewed, and
  pinned.
- **The committed template never carries a credential; the rendered file is an
  ephemeral secret.** Unattended setup requires an administrator password, and a
  committed answer file containing one would publish it. The repository holds a
  template with placeholders. The file actually handed to setup holds a working
  credential for as long as it exists, so it is rendered to a restricted
  location, removed on every exit path including failure, and never treated as
  safe on the grounds that the template was.
- **Provenance records the media.** The media reference, its expected checksum,
  and the answer-file revision belong in the provenance record beside the
  manifest and package hashes. Which evidence contract carries that record is
  decided in Increment 3 stage 3, not assumed: `evidence-envelope-2` has closed
  payloads and a bounded `resultKind`, and an image-build result does not join
  it by default.

- **Qualification fingerprints media; it does not inspect it.** Verifying a
  digest establishes which artifact is present. It does not establish that the
  artifact contains the edition, architecture, or language the reference
  declares -- those are recorded intent, reconciled against the installed
  operating system by the pre-seal checks.

## Alternatives considered

**Consume an existing image source.** Rejected as the primary path. It inherits
provenance instead of establishing it, and would make the repository a
demonstration of provisioning rather than of deterministic construction. It is
cheaper to implement and faster to run, which is precisely why it would have
settled this decision by inertia had implementation started before the decision
was recorded.

**Media path as the stated target, existing-image path implemented first.**
Rejected. The reversible-first instinct is usually right, but here the two paths
diverge at the builder, the qualification domain, the answer-file contract, and
the provenance record. Little of the intermediate work would survive, and the
stated target would sit unimplemented behind a working alternative -- which is
how a placeholder becomes the architecture.

**Accept both as first-class paths.** Rejected for now. Supporting two base-image
strategies doubles the qualification surface before either has been proven once.
Revisit only if a concrete requirement appears; nothing here forecloses it.

## Consequences

- Increment 3 grows: media acquisition and verification, an answer-file contract,
  and a vSphere builder configuration all land inside it.
- Most of Increment 3 cannot be proven by CI. Media qualification, the
  answer-file contract, identity derivation, and provenance are host-side and
  testable; the builder, generalization, shutdown, and sealing need a lab.
  Section 33.1's verification levels apply, and the increment closes as
  **implementation complete; lab validation pending** unless a lab exists.
- Build duration increases substantially compared to customizing a template. That
  is an accepted cost of stating what is in the image.
- A first build needs media and a checksum obtained from the vendor. Neither is
  committed; the repository references them and verifies what it is given.

## Validation implications

- A media reference whose checksum does not match must fail the build, and a test
  must prove the mismatch is detected rather than only that a match passes.
- The checksum must come from a source separate from the artifact. A test should
  reject a design where the expected value is read from beside the artifact it
  claims to verify.
- Rendering the answer file must fail closed on an unsubstituted placeholder, and
  a test must supply one and see the failure.
- The rendered answer file must never be written into the repository tree, and
  the boundary check must see the template rather than a rendered copy.
- Sealing must produce an identity derived from the construction inputs. A test
  asserting only that some identifier exists would pass against a timestamp or a
  display name, which section 9's glossary explicitly excludes.
- Checksum-authority independence is **not** proven by code and must not be
  described as though it were. The contract narrows it structurally -- one
  authority kind, and a citation that must be an HTTPS reference rather than a
  path -- and a reviewer attests that the cited location belongs to the media's
  publisher. A test suite cannot establish that last part, and a rule that
  appeared to would invite the review to be skipped.
