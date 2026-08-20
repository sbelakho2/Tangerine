# Tangerine RFC Process

## What is an RFC?

An RFC (Request For Comments) is a design document proposing a significant change
to the Tangerine language, standard library, compiler, or toolchain. RFCs ensure
that major changes are discussed, reviewed, and documented before implementation.

## When is an RFC Required?

An RFC is required for:

- **Language changes**: New syntax, new keywords, semantic modifications,
  changes to the type system, borrow checker, or trait system.
- **Standard library additions**: New modules, new public types or functions,
  changes to existing API signatures.
- **Compiler changes**: New optimization passes, changes to the MIR, new
  codegen backends, changes to the build system.
- **Toolchain changes**: New subcommands, changes to the package manager
  protocol, changes to the LSP protocol extensions.
- **Breaking changes**: Any change that could break existing valid Tangerine code.

An RFC is NOT required for:

- Bug fixes.
- Performance improvements that don't change observable behavior.
- Documentation improvements.
- Refactoring that doesn't change public APIs.
- Adding compiler error messages or improving diagnostics.

## RFC Lifecycle

```
Draft → Proposed → Under Review → Accepted → Implemented → Stable
                       ↓
                   Rejected / Deferred
```

### 1. Draft

Author writes the RFC using the template below and opens a pull request to
the `rfcs/` directory. The filename should be `0000-feature-name.md` (the
number is assigned upon acceptance).

### 2. Proposed

The core team triages the RFC and assigns reviewers. A minimum discussion
period of **14 days** is enforced.

### 3. Under Review

- Community members and reviewers leave feedback.
- The author revises the RFC based on feedback.
- At least **two core team members** must approve.

### 4. Decision

- **Accepted**: RFC is assigned a number and merged. A tracking issue is created.
- **Rejected**: The PR is closed with a summary of reasons.
- **Deferred**: Pushed to a future milestone. The PR stays open.

### 5. Implementation

The accepted RFC is implemented. The tracking issue links to implementation PRs.
The RFC may be amended during implementation if minor adjustments are needed
(with reviewer approval).

### 6. Stabilization

Features land behind a feature gate (e.g., `@feature(my_feature)`).
After sufficient testing and feedback, a stabilization PR is filed to remove
the gate and make the feature available by default.

## RFC Template

```markdown
# RFC NNNN: Feature Name

- **RFC PR**: (link to PR)
- **Tracking Issue**: (link to issue, filled after acceptance)
- **Status**: Draft | Proposed | Accepted | Implemented | Stable

## Summary

One-paragraph explanation of the feature.

## Motivation

Why is this change needed? What problems does it solve?
What use cases does it enable?

## Detailed Design

Technical specification. This should be detailed enough for someone
to implement the feature from this document alone.

### Syntax

If the RFC changes syntax, provide the grammar rules:

```
new_expression := ...
```

### Semantics

Describe the runtime/compile-time behavior.

### Examples

```tangerine
# Example usage of the proposed feature
```

## Drawbacks

Why might we NOT want to do this?

## Alternatives

What other designs were considered? Why was this design chosen?

## Unresolved Questions

What parts of the design need further discussion?

## Future Possibilities

What future extensions could build on this RFC?
```

## Governance

### Core Team

The core team consists of maintainers with merge rights. They are responsible
for RFC triage, review, and final decisions.

### Decision Process

- Decisions are made by **consensus** among core team reviewers.
- If consensus cannot be reached, the project lead makes the final call.
- Any core team member can raise a **concern** that blocks acceptance until resolved.

### Amendments

Accepted RFCs can be amended via a follow-up RFC or a lightweight amendment PR
(for non-controversial changes). Amendments require one core team approval.

## Repository Structure

```
rfcs/
  0001-block-closures.md
  0002-match-arm-syntax-unification.md
  0003-mode-system.md
  0004-capability-and-effects.md
  0005-cqs-and-cws.md
  ...
  template.md
```
