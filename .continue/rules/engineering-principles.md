---
name: Reference Repository Engineering Rules
description: Scope, architecture, integrity, and engineering constraints for this repository
alwaysApply: true
---

# Reference Repository Engineering Rules

## Public repository boundary

This repository is public. Never write names identifying individuals,
affiliations, or organization-specific identifiers belonging to a non-public
context; internal hostnames, addresses, account or tenant identifiers, or
network topology; credentials, tokens, or private keys; or any value copied from
a non-public source.

Naming a technology vendor or product is expected. What must not appear is an
identity or affiliation belonging to a non-public context.

Naming conventions, exact scale, deployment structure, and approval processes
reveal origin through their shape even after names are removed. Content belongs
here only if it could be written independently from public vendor documentation
and general engineering knowledge.

If non-public information appears in a task, substitute an obviously fictional
placeholder and say that you did.

## Scope

Implement only the current requested increment.

Do not create future-phase functionality unless explicitly requested.

Do not scaffold speculative abstractions.

## Architecture

Architecture decisions precede consequential implementation decisions.

Distinguish OBSERVED, INFERRED, PROPOSED, and DEFERRED.

Do not treat the target architecture as evidence of current implementation.

## Software inputs

Package manifests describe image recipes, not deployment policy.

Use exact versions and exact source references.

Do not use latest, wildcard resolution, or automatic package discovery.

Expected SHA-256 values are established before runtime.

Host verifies package integrity before transfer.

Guest re-verifies against the same expected SHA-256 after transfer.

Integrity failure is fail-closed.

## Responsibilities

Definitions declare.
Scripts execute.
Contracts define boundaries.
Tests prove behavior.
CI orchestrates.

## Engineering

Prefer the smallest implementation satisfying the current requirement.

Do not introduce generalized frameworks where explicit scripts or functions
suffice.

Do not commit secrets or installer binaries.

Preserve evidence required to explain build outcomes.
