# Contracts: Rules — Impact Audit (P7) + UI Verification

**Spec**: [../spec.md](../spec.md)
**Scope**: research (Phase 1 — external contracts)
**Date**: 2026-05-21

## No contracts produced by this spec

This spec ships rule content only (two `.mdc` files governed by `rules/00-architecture/0-rules-structure.mdc`). It introduces:

- No HTTP / RPC / gRPC API surface
- No CLI command surface
- No JSON / YAML / protobuf message schema consumed or emitted by code
- No database schema or migration
- No event / queue contract

Therefore this directory holds a single placeholder file (this README) for traceability. ANALYZE phase should treat the absence of API / schema artifacts as expected, not as a gap.

The closest thing to a "contract" introduced by this spec is the **frontmatter schema** for `.mdc` rule files. That schema is governed by `rules/00-architecture/0-rules-structure.mdc` (the de-facto constitution for rule edits) and described in this spec's [`../data-model.md`](../data-model.md) under the `RuleFile` entity. It is intentionally documented in `data-model.md` rather than `contracts/` because it is an internal authoring shape, not an external interface.
