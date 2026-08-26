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
| artifact identity | which object resulted | vCenter instance id + managed object reference + VM instance UUID | the platform |

Two builds from identical inputs share a `recipeDigest` and differ in `runId`
and artifact identity. Change any input and all three differ. A build that fails
before sealing has the first two and not the third, which is exactly how a
failed build should be describable.

### What `recipeDigest` is computed over

The digest is taken over a **canonical recipe-input document**, itself versioned
as `recipe-input-1`. Introducing a field, removing one, or changing how a value
is represented produces `recipe-input-2`; the digest of a given recipe is only
comparable within one version, and the version is recorded beside the digest.

#### Canonical form

Sorting object keys is not sufficient, so every representational choice is
fixed:

| Aspect | Rule |
| --- | --- |
| Encoding | UTF-8, no byte-order mark |
| Object keys | sorted by ordinal code point, not by culture |
| Arrays that carry sequence | **left in declared order** |
| Arrays that carry a set | sorted by a named key, stated per field below |
| Maps (for example MSI properties) | serialized as key-sorted objects |
| Integers | shortest decimal form, no leading zeros, no exponent |
| Booleans | `true` / `false` |
| Strings | verbatim; no case folding, trimming, or normalization |
| Absent optional values | omitted entirely, never `null` |
| Whitespace | none between tokens |
| Digest | SHA-256 over the resulting bytes |

Package order is semantic, and the sequence is the ascending explicit `order`
value -- not the position a package happens to occupy in the file. **Packages
are serialized in ascending `order`.**

Two consequences, both of which must hold:

- reordering the package array while every explicit `order` value stays the same
  describes the same installation, and **must not** change the digest;
- changing an `order` value changes what installs when, and **must** change it.

A digest taken over array position would get both of these backwards.

#### Included

**Media.** `mediaId`, hash algorithm and expected digest, image edition and
index, architecture and language. The expected digest, never the observed one:
the recipe says what the media must be; an observation is a fact about one run.

**Packages.** The manifest schema version, and the package array in declared
order. For each package, everything that can change what is installed or whether
the result is accepted:

- `id`, `version`, and the expected SHA-256, which the contract names `sha256`
  at the package root -- `source` is the reference string, not a container;
- `order` and `required`;
- installer `kind`;
- the MSI property map (key-sorted) or the EXE argument tokens **in declared
  order**, since arguments are positional;
- `timeoutSeconds`, `restartPolicy`, and the exit-code policy. `restartRequired`
  is optional in the contract and is included only when declared, so an absent
  policy and an explicitly empty one stay distinguishable;
- the validation definitions, in declared order.

Validation definitions are included rather than treated as separate policy. A
change to what is checked changes whether a given image is accepted, and an
image accepted under weaker checks is not interchangeable with one accepted
under stronger ones. If acceptance policy is later versioned independently, it
becomes a named `acceptancePolicyDigest` field inside this document rather than
disappearing from it.

**Answer file.** The SHA-256 of the committed template and of its declaration,
plus the declared image selection. Never the rendered file, which contains a
credential.

**Build logic that affects content.** Implementation changes can alter an image
without touching any of the above, so the recipe covers them:

- the SHA-256 of the Packer build configuration files that contribute to
  construction;
- the SHA-256 of each provisioning script delivered into the guest, and the
  guest provisioning contract version;
- the virtual hardware and firmware selections: hardware version, firmware type,
  secure boot state, disk controller and sizing, and vTPM presence.

Without these, editing a provisioning script or switching firmware would produce
a different image under an unchanged digest, which is the failure mode this
whole mechanism exists to prevent.

#### Excluded, deliberately

- **Credentials and anything derived from them.** The digest is published in
  provenance; nothing that could narrow a secret may contribute to it.
- **Run-specific values**: `runId`, timestamps, temporary paths, evidence output
  locations, the cleanup nonce.
- **Environment-specific values**: hostnames, vCenter instance, cluster,
  datastore, network, folder and resource-pool names, and every vSphere object
  identifier. Two sites building one recipe must reach the same digest, or the
  digest describes the site.
- **Observed results**: the media's observed digest, package outcomes, timings.
  They belong in the record beside the digest, not inside it.

The rule that decides membership: **if changing it could change what is
installed or whether the result is accepted, it is an input; if it only changes
where or when the build ran, it is not.**

#### Byte-level identity for file inputs, deliberately conservative

The template, declaration, Packer configuration, and provisioning scripts enter
by file digest, so a comment or a reformatting changes `recipeDigest` even
though nothing installed changes. That contradicts a strict reading of the
membership rule, and the contradiction is resolved in favour of the conservative
option:

**An input's identity may be coarser than its semantics. The digest must never
miss a change that matters; it may report one that does not.**

A false positive costs a rebuild. A false negative means two materially
different images share an identity, and every downstream claim built on that
identity is wrong. These are not comparable costs.

The alternative — canonicalizing only the operationally significant fields of
each file — was rejected. It requires deciding which parts of an answer file, a
Packer configuration, and a provisioning script are operational, a judgment that
must be revisited on every edit and that fails silently and permissively when
wrong. The raw file digests are recorded in provenance regardless, so the
conservative choice loses no information.

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
will reject a version 3 document. That is what a version is for.

**Support policy**, stated because external use of a public repository is not
observable and cannot be assumed absent: a published contract version is never
edited in place. Changes ship as a new version alongside it, the previous
version's file stays byte-stable, and a test asserts that documents which
validated under it still do. Anything consuming `evidence-envelope-2` continues
to work; nothing is required to adopt version 3.

### Artifact identity is scoped, and waits for lab evidence

A managed object reference is unique only within one vCenter instance, and the
name recorded against a VM is mutable. Neither alone identifies an artifact.
Artifact identity is therefore all three:

| Field | Role |
| --- | --- |
| vCenter instance identifier | the scope the reference is unique within |
| managed object reference | the object within that scope |
| VM instance UUID | survives a rename, and distinguishes a restored or re-registered object |
| recorded name | **display metadata only**, never an identifier, and optional |

All three of the first rows are required together. Any one of them alone is
ambiguous: a reference is scoped to an instance, and a name can be changed by
anyone with permission to rename a VM.

These are environment-specific and therefore excluded from `recipeDigest`
entirely. They appear only in a provenance record produced by a real build,
which is also the only place they can be observed.

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
- Synthetic artifact identities are appropriate in contract tests, and every
  one must be labelled as invented at the point it is created. They exercise the
  shape; they are never evidence that a platform artifact exists, and no
  synthetic identity may be cited as a build having run.
- The manifest contract version a build result claims must be one the recipe
  path can process. The envelope admits version 1 because other result kinds
  carry it legitimately; an image build cannot, since a version 1 package has no
  installer or validation fields for the recipe to read.
- A provenance record containing a credential, in any field, must be refused.
  Asserting the absence of one specific key is not enough; the test should
  search the serialized document for a canary value supplied as a secret.
- A version 2 envelope that validated before version 3 existed must still
  validate, proven by a test, and dispatch must refuse an unknown version rather
  than falling back to the newest.
- A sealed candidate must carry every build obligation the charter defines,
  once each, in order, passed, and naming no failure: media qualification, the
  answer file, construction, provisioning, pre-generalization checks, credential
  and residue removal, generalization, an observed shutdown, the seal itself,
  and complete provenance. A single passed seal phase is a seal event, not a
  build, and must not promote anything.
- The gate that answers "is this a sealed candidate" must establish schema
  validity itself rather than assuming a caller validated first, and must refuse
  a recipe-input version it does not implement.
- Absent artifact identity must be accepted for failed, incomplete, and pre-seal
  records, and required only for a positively sealed result. A record must never
  be reported as a sealed candidate on the strength of the document alone.
- Every included input needs a case proving the digest moves when it changes,
  and the package array needs one proving a reordering changes it, since
  sorting the sequence away is the most natural mistake to make.
- Canonicalization needs cases for each representational rule: key ordering,
  integer form, an omitted optional value against an explicit null, and a map
  serialized from two different insertion orders.
- Schema patterns must be ECMA-262 compatible. Envelope version 3 needs the same
  semantic control-character rejection the package and transfer paths already
  have, because a portable pattern cannot close that gap under .NET.
