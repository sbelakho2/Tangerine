# RFC 0005: CQS and Context Widening System

- RFC Number: 0005
- Title: CQS and Context Widening System
- Author: Tangerine Core Team
- Status: Accepted
- Created: 2025-03-18
- Edition: 2026

## Summary

Define the normative structure of Completeness/Quality Scoring (CQS) and the
Context Widening System (CWS), including canonical signals, scoring composition,
and policy integration points.

## Motivation

CQS/CWS are central to quality gates but were mostly documented in implementation
comments. A formal RFC improves consistency for tools and ecosystem integrations.

## Detailed Design

### CQS

- Signals are normalized to severity in [0, 1].
- Suppression and mode/profile modifiers are applied before aggregation.
- Final score drives warning/error/block decisions.

### CWS

- Symbol graph and dependency information determine context expansion.
- Selection is constrained by budgets and deterministic ordering.

### Artifacts

- Quality and context artifacts are versioned and schema-checked.

## References

- `tg_compiler/cqs.tg`
- `tg_compiler/symbol_graph.tg`
- `docs/cqs_quality.schema.json`
- `docs/ctxpack.schema.json`
