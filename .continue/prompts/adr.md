---
name: adr
description: Draft an architecture decision record for a consequential decision
invokable: true
---

First, decide whether this decision warrants an architecture decision record.

It does if it changes a cross-domain contract, establishes a security or trust
boundary, selects a state or lifecycle boundary, introduces a major dependency,
is costly to reverse, or rejects a plausible alternative for a durable reason.

It does not for a function name, folder spelling, minor script structure,
logging wording, or test fixture location.

If it does not warrant one, say so and stop.

If it does, draft it for `docs/decisions/` with these sections:

- Title
- Status (proposed, accepted, superseded)
- Context — the forces and constraints, stated without private detail
- Decision — what was chosen, in the active voice
- Alternatives considered — and why each was rejected
- Consequences — including the ones that are inconvenient
- Validation implications — what must now be tested or evidenced
