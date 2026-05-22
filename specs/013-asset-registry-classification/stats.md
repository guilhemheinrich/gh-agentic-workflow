# AI Processing Stats: Asset Registry Classification

**Feature**: `013-asset-registry-classification`
**Created**: 2026-05-22
**Last Updated**: 2026-05-22

## Summary

| Metric                      | Value          |
| --------------------------- | -------------- |
| Total AI Sessions           | 1              |
| Total AI Duration           | ~10m           |
| Total Human Effort Estimate | ~1.5 j/h       |
| AI vs Human Ratio           | ~63:1          |
| Primary Model               | Claude Opus 4.7 |

## Session Log

### Session 1: /specify

| Field                 | Value                                            |
| --------------------- | ------------------------------------------------ |
| Command               | `/specify`                                       |
| Date                  | 2026-05-22                                       |
| Model                 | Claude Opus 4.7 (anthropic, Cursor)              |
| Start Time            | 14:12                                            |
| End Time              | 14:21                                            |
| Est. Duration         | ~9m                                              |
| Human Effort Estimate | ~1.5 j/h                                         |
| Files Created         | 17                                               |
| Files Modified        | 0                                                |
| Tasks Generated       | 60                                               |
| Status                | ✅ Success                                       |

**Notes**: Spec produced for refactoring `asset-registry.yml` and `asset-registry.schema.json` into a 3-axis (category × bundles × tags) model aligned with `rules/00-…09-*/`. Includes 9 negative + 2 positive validation fixtures, a Dockerised ajv validation harness, and a deterministic audit query bank.
No `[NEEDS CLARIFICATION]` left open — user prompt was already exhaustive.

## Per-Command Aggregation

| Command                | Sessions | Total AI Duration | Total Human Effort | Avg AI Duration | Files Impacted |
| ---------------------- | -------- | ----------------- | ------------------ | --------------- | -------------- |
| `/specify`             | 1        | ~9m               | ~1.5 j/h           | ~9m             | 17             |
| `/implement`           | 0        | —                 | —                  | —               | —              |
| `/implement review.md` | 0        | —                 | —                  | —               | —              |
| `/review-implement`    | 0        | —                 | —                  | —               | —              |

## Effort Legend

| Unit | Meaning        | Equivalence     |
| ---- | -------------- | --------------- |
| j/h  | person-day(s)  | 1 j/h = 7h work |
| s/h  | person-week(s) | 1 s/h = 5 j/h   |
