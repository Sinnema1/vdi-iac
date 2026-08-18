---
name: review
description: Review current changes against repository architecture and engineering rules
invokable: true
---

@Git Diff

Review these changes against the repository architecture and engineering rules.

Identify:

- correctness defects
- scope creep
- unnecessary abstractions
- hidden assumptions
- security concerns
- missing validation
- missing evidence
- architectural boundary violations
- any content that breaches the public repository boundary

Distinguish blocking findings from optional improvements.
