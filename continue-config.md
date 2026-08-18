# Continue Configuration Recommendations

This configuration provides a strong starting point, with three adjustments recommended before it is treated as stable.

The strongest part of the proposal is the operating philosophy:

```text
Architecture / reasoning first
→ smallest implementation increment
→ explicit context
→ inspect diff
→ validate
→ record consequential decisions
```

That is exactly the behavior we want for this reference repository.

## My assessment

| Proposed direction | Verdict | Adjustment |
| --- | --- | --- |
| Mistral Medium 3.5 for architecture/planning | **Keep** | Use primarily as the `chat` model and with Plan Mode |
| Gemma 4 31B for editing/code generation | **Keep provisionally** | Assign `edit`/`apply` after a small bake-off |
| `@Repository Map`, `@Tree`, `@Current File`, `@Git Diff` | **Keep** | These are current Continue context providers |
| Custom `/next-step`, `/review`, `/adr`, `/sprint-check` | **Keep** | Implement as Continue prompts/slash commands |
| Persistent workspace rule file | **Definitely keep** | Put machine-consumed rules under `.continue/rules/` |
| Conservative autocomplete | **Keep** | Do not assume either general-purpose model is ideal for autocomplete |
| Architecture decision log | **Keep** | Only create ADRs for consequential decisions |
| “Current sprint first” guardrail | **Strongly keep** | Generalize from sprint numbers to current work-item scope |

Continue supports assigning different models to roles such as `chat`, `edit`, `apply`, and `autocomplete`, so role-based routing is preferable to manually selecting a model for every task.

---

## 1. Keep the model split, but treat it as an empirical starting hypothesis

I agree with:

```text
Mistral Medium 3.5
→ architecture
→ requirements analysis
→ design discussion
→ planning
→ review

Gemma 4 31B
→ PowerShell
→ HCL
→ YAML
→ Markdown
→ targeted refactoring
```

But I would **not encode “Mistral reasons better / Gemma codes better” as an architectural truth yet**.

Instead:

```text
Initial routing hypothesis

Mistral
roles:
  - chat

Gemma
roles:
  - edit
  - apply
```

Continue supports this kind of model-role separation. If no dedicated edit/apply model is configured, the chat model can fall back into those functions, which is another reason to assign the roles intentionally.

Then do a very small bake-off.

For example, give both models the same tasks:

```text
Task A
Review a package-manifest design for scope creep.

Task B
Write a PowerShell function that verifies SHA-256
and fails closed.

Task C
Modify a small Packer provisioner block
without touching unrelated behavior.

Task D
Review @Git Diff and identify architectural drift.
```

Judge:

```text
correctness
scope discipline
hallucination rate
unnecessary abstraction
PowerShell quality
HCL quality
ability to follow repository rules
```

Then adjust the routing from evidence.

That is safer than assuming model characteristics from general reputation.

---

## 2. I would change the workspace-rule recommendation

A common alternative layout is:

```text
.ai/rules.md
```

or:

```text
docs/ai-engineering-principles.md
```

For **Continue's machine-consumed project rules**, I would instead use:

```text
.continue/
└── rules/
    └── engineering-principles.md
```

Continue supports local, version-controlled project rules under `.continue/rules/`; those rules are automatically applied to Agent, Chat, and Edit requests.

You can still have:

```text
docs/ai-engineering-principles.md
```

for humans if you want.

But I would separate:

```text
.continue/rules/
    AI operating constraints

docs/
    engineering documentation for humans
```

### Recommended initial rule content

I would keep it short:

```text
# Reference Repository Engineering Rules

## Scope

Implement only the current requested increment.

Do not create future-phase functionality unless explicitly requested.

Do not scaffold speculative abstractions.

## Architecture

Architecture decisions precede consequential implementation decisions.

Distinguish OBSERVED, INFERRED, PROPOSED, and DEFERRED.

Do not treat the target architecture as evidence of current implementation.

## Software Inputs

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

Do not introduce generalized frameworks where explicit scripts/functions suffice.

Do not commit secrets or installer binaries.

Preserve evidence required to explain build outcomes.
```

I would **not put the entire large bootstrap prompt into the rules file**.

That would consume context continuously and make the important constraints less salient.

---

## 3. Use Plan Mode as the default planning boundary

This is probably the biggest improvement I would make.

Continue has a dedicated **Plan Mode** for read-only exploration, implementation planning, issue investigation, and architecture analysis. It can inspect files, directories, repository structure, searches, and Git history or diffs without modifying the workspace.

So your workflow should really become:

```text
PLAN MODE
Mistral Medium 3.5

Understand
→ inspect
→ architecture
→ alternatives
→ risks
→ smallest increment

             ↓ approval

EDIT / AGENT
Gemma 4 31B

Implement bounded change

             ↓

PLAN / CHAT REVIEW
Mistral Medium 3.5

@Git Diff
→ architectural conformance
→ scope creep
→ validation
→ rollback
```

That is stronger than relying entirely on prompt wording such as:

> Do not build the entire world.

The platform provides a read-only boundary for the planning phase.

---

## 4. Recommended context strategy

Use these context providers when applicable:

```text
@Repository Map
@Tree
@CurrentFile
@Git Diff
```

I agree.

Continue provides each of these as built-in context providers. `@Tree` exposes workspace structure, `@Repository Map` provides a codebase outline and signatures, `@Current File` provides the active file, and `@Git Diff` provides current branch changes for review.

I would use them by purpose:

| Question | Context |
| --- | --- |
| “What exists?” | `@Tree` |
| “How is this repo organized?” | `@Repository Map` |
| “Work on this script” | `@Current File` |
| “Review this specific implementation” | `@File` / `@Code` |
| “Why did this command fail?” | `@Terminal` |
| “Review what we just changed” | `@Git Diff` |

`@Git Diff` should become routine before accepting AI-generated changes because it supports review before committing.

One caution: don't mechanically attach:

```text
@Repository Map
@Tree
@CurrentFile
@Git Diff
```

to **every** prompt.

Use only the context needed.

Otherwise you're paying context-window cost and distracting the model with irrelevant material.

---

## 5. Custom slash commands are a good idea

I agree with:

```text
/next-step
/review
/adr
/sprint-check
```

Continue supports invokable prompts that appear as `/` commands in Chat, Plan, and Agent modes.

For this project I would actually use these five:

```text
/next-step
/review
/adr
/scope-check
/evidence-check
```

I prefer:

```text
/scope-check
```

over:

```text
/sprint-check
```

because the repository should not permanently encode an iteration-specific operating assumption.

The rule we actually care about is:

> Does this change belong to the **current accepted work item/increment**?

That survives changes in planning tools, iteration models, and delivery methods.

### `/next-step`

```text
Identify the smallest justified implementation increment.

Do not implement or propose unrelated future work.
Do not scaffold unused abstractions.

State:

- Why
- Change
- What remains unchanged
- Validation
- Risks
- Rollback
```

### `/review`

Use with `@Git Diff`:

```text
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

Distinguish blocking findings from optional improvements.
```

### `/scope-check`

```text
Determine whether the proposed change is necessary for the current work item.

Classify it as:

REQUIRED
SUPPORTING
DEFERRED
OUT OF SCOPE

Do not recommend implementing DEFERRED or OUT OF SCOPE items.
```

### `/evidence-check`

```text
For the proposed or completed implementation, identify:

- what behavior is being claimed
- what evidence proves it
- what evidence is still missing
- how the evidence should be produced
- whether failure behavior is observable
```

Those should considerably reduce wandering.

---

## 6. ADRs: yes, but don't turn every decision into one

The recommendation to maintain:

```text
docs/decisions/
```

is sound.

I would use ADRs for decisions such as:

```text
software source = governed file share
guest does not access source directly
expected SHA-256 belongs in manifest
Packer owns restart boundary
image-build state and catalog-provisioning state are separate
```

I would **not** create ADRs for:

```text
function name
folder spelling
minor script structure
logging wording
test fixture location
```

The decision threshold should be roughly:

> Would a future engineer reasonably ask, “Why did they choose this architecture instead of the obvious alternative?”

If yes, ADR candidate.

---

## 7. I would be even more conservative with autocomplete

For autocomplete, use:

```text
Autocomplete: ON
Large multi-line completions: OFF
```

That is reasonable.

Continue treats autocomplete as its own model role, separate from chat, edit, and apply behavior.

Because your available models are constrained, I would initially treat autocomplete as convenience rather than a design tool:

```text
Autocomplete
→ small statements
→ obvious syntax
→ repetitive code

Chat/Edit
→ functions
→ HCL blocks
→ manifests
→ architectural changes
```

In particular, I would manually inspect autocomplete suggestions involving:

```text
PowerShell error handling
SHA-256 validation
credentials
Packer provisioners
Terraform
CI
```

Those are precisely where a plausible-looking completion can silently change behavior.

---

## 8. One thing I would add: explicit mode boundaries

I would define your default working loop as:

```text
┌─────────────────────────────────────┐
│ 1. PLAN                            │
│ Mistral Medium 3.5                 │
│                                    │
│ @Tree / @Repository Map / @Files   │
│ Understand before changing         │
└──────────────────┬──────────────────┘
                   │
                   ▼
        Human approves direction
                   │
                   ▼
┌─────────────────────────────────────┐
│ 2. IMPLEMENT                       │
│ Gemma 4 31B                        │
│                                    │
│ @Current File / targeted files     │
│ Small bounded change               │
└──────────────────┬──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│ 3. VALIDATE                        │
│ Tests / Packer / PowerShell        │
└──────────────────┬──────────────────┘
                   │
                   ▼
┌─────────────────────────────────────┐
│ 4. REVIEW                          │
│ Mistral Medium 3.5                 │
│                                    │
│ @Git Diff                          │
│ /review                            │
└──────────────────┬──────────────────┘
                   │
                   ▼
          Accept / revise / revert
```

Continue's Plan Mode is particularly well matched to the first stage because it prevents file edits and terminal execution while still allowing repository exploration and analysis.

---

## Recommended Continue configuration philosophy

I would therefore settle on:

```text
CHAT / PLAN
Mistral Medium 3.5

Primary use:
architecture
requirements
repository analysis
alternatives
risk analysis
review
ADRs
scope decisions


EDIT / APPLY
Gemma 4 31B

Primary use:
targeted PowerShell
HCL
YAML
Markdown
tests
small refactors


AUTOCOMPLETE
Conservative / experimental

Primary use:
small local completions
not architectural generation
```

with:

```text
.continue/rules/
    engineering-principles.md

docs/
    decisions/
```

and the habitual context set:

```text
@Tree
@Repository Map
@Current File
@File
@Code
@Terminal
@Git Diff
```

plus:

```text
/next-step
/review
/scope-check
/adr
/evidence-check
```

## Final assessment

**Yes — I would proceed in this direction.**

This configuration positions Continue as a **bounded engineering assistant rather than an autonomous code generator**, which is appropriate for this repository.

The two changes I consider most important are:

```text
1. Put durable AI rules in .continue/rules/
2. Make Plan Mode → approval → implementation → @Git Diff review
   the default engineering loop
```

Treat the Mistral/Gemma split as an **initial routing hypothesis**, then validate it with a few representative repository tasks before making it permanent.
