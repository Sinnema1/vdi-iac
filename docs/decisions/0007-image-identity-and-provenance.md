# 7. Image identity, provenance, and the build-result contract

## Status

Accepted. Implementation is Increment 3 stage 3. No image has been built or
sealed, and no provenance record has been produced by a real build.

## Context

Increment 3 produces a sealed candidate image. For that artifact to be usable by
anything downstream — validation, promotion, rollback, retirement — three
questions must be answerable, and they are different questions:

- **What was built?** The inputs that determine the image's content.
- **Which run built it?** The execution that produced this particular attempt.
- **Which artifact resulted?** The immutable object now sitting in vSphere.

Collapsing any two makes one of them unanswerable. If identity is derived from
the run, two builds from identical inputs get different identities and nothing
can recognise them as the same recipe. If identity is the vSphere object, the
recipe has no name until a build succeeds, so a failed build cannot be described
at all. If the artifact is identified by its recipe, two successful builds from
one recipe collide and one silently stands for the other.

Increment 3 also produces a new kind of evidence. `evidence-envelope-2` has
closed payloads and a bounded `resultKind`, so an image-build result does not
belong to it by default and cannot be added by editing an enum in passing.

## Decision

### Three identities, all bound in provenance

| Concept | Answers | Shape | Determined by |
| --- | --- | --- | --- |
| `recipeDigest` | what was built | SHA-256 over canonical inputs | the inputs alone |
| `runId` | which execution built it | canonical UUID, already defined by ADR 5 | the run |
| artifact identity | which object resulted | vSphere managed object reference plus its recorded name | the platform |

Two builds from identical inputs share a `recipeDigest` and differ in `runId`
and artifact identity. Change any input and all three differ. A build that fails
before sealing has the first two and not the third, which is exactly how a
failed build should be describable.

### What `recipeDigest` is computed over

Canonical, non-secret, and environment-independent. The digest is taken over a
canonical JSON serialization — keys sorted, no insignificant whitespace, UTF-8
without a byte-order mark — so the same inputs produce the same digest on any
machine.

Included:

- **Media**: `mediaId`, hash algorithm and expected digest, image edition and
  index, architecture and language. The expected digest, never the observed
  one: the recipe says what the media must be, and an observation is a fact
  about one run.
- **Packages**: the manifest schema version, and for each package its
  identifier, version, and expected SHA-256, ordered canonically. Not the
  manifest file's own digest, which would change with a reordering or a comment
  that alters nothing about what gets installed.
- **Answer file**: the SHA-256 of the committed template and of its declaration,
  plus the declared image selection. Never the rendered file, which contains a
  credential.
- **Tooling**: the Packer version, the pinned plugin versions, and the version
  of the guest provisioning contract in use.

Excluded, deliberately:

- **Credentials and anything derived from them.** A recipe digest is published
  in provenance; nothing that could narrow a secret may contribute to it.
- **Run-specific values**: `runId`, timestamps, temporary paths, evidence
  output locations, the cleanup nonce. These differ between two builds that
  ought to be recognised as identical.
- **Environment-specific values**: hostnames, cluster, datastore, network, and
  folder names, resource pools, and any vSphere object identifier. Two sites
  building the same recipe must arrive at the same digest, or the digest
  describes the site rather than the image.
- **Observed results**: the media's observed digest, package validation
  outcomes, timings. These describe what happened, not what was asked for, and
  belong in the record beside the digest rather than inside it.

The rule that decides membership: **if changing it would change what is
installed, it is an input; if it would only change where or when the build ran,
it is not.**

### The build result extends the evidence contract as version 3

`evidence-envelope-3` is a new contract file adding the `image-build` result
kind and its payload. `evidence-envelope-2` is left exactly as it is.

This follows the pattern the manifest contract already established: a new
version is a new file, dispatch is a hard-coded version map, and a test asserts
the older version still validates what it validated before. Envelope fields the
repository already defines and tests — run identity, outcome vocabulary,
timestamps, redaction rules — are reused rather than restated.

**A separate build-result contract was rejected.** It would duplicate the
envelope's correlation fields and introduce a second place where the rules for
run identity and redaction are written, which is the arrangement that produces
two subtly different definitions of the same thing. The repository has already
been bitten by exactly that: the evidence consistency rules existed twice with
different coverage until they were consolidated.

The cost is real and accepted: a consumer validating strictly against version 2
will reject a version 3 document. That is what a version is for, and there is no
external consumer today.

### Artifact binding waits for lab evidence

The provenance record's artifact identity is **absent until a real vSphere build
produces one**. A record without it describes a recipe and a run that did not
reach a sealed artifact, which is a legitimate and useful thing to record.

No schema will carry a placeholder artifact identity, no test will assert
against a fabricated managed object reference, and nothing is described as a
sealed candidate on the strength of a document alone. The sealing gate in stage
5 is what promotes a record from "a build ran" to "this candidate exists", and
it cannot run in CI.

## Consequences

- Stage 3 delivers the `recipeDigest` computation, the provenance payload, and
  `evidence-envelope-3`, all CI-provable against fixtures.
- The digest is a published value. Its inputs are reviewable, and the exclusion
  list above is part of the contract rather than an implementation detail.
- A recipe digest changing unexpectedly is a signal worth acting on: it means an
  input changed. Tests must therefore prove stability across reordering and
  across machines, not merely that a digest is produced.
- Provenance records exist for builds that never sealed. Consumers must read
  artifact identity as optional and must not treat its absence as corruption.

## Validation implications

- Two fixtures with identical inputs in different key orders must produce the
  same digest. A test that only checks a digest is non-empty would pass against
  an implementation that hashed a hashtable's enumeration order.
- Changing each included input in turn must change the digest, one case per
  input. A digest that ignores an input it claims to cover is the failure this
  is most exposed to.
- Changing an excluded value — `runId`, a timestamp, a datastore name, a
  temporary path — must leave the digest unchanged, one case per exclusion.
- A provenance record containing a credential, in any field, must be refused.
  Asserting the absence of one specific key is not enough; the test should
  search the serialized document for a canary value supplied as a secret.
- A version 2 envelope that validated before version 3 existed must still
  validate, proven by a test, and dispatch must refuse an unknown version rather
  than falling back to the newest.
- Absent artifact identity must be accepted, and a record must never be reported
  as a sealed candidate on the strength of the document alone.
