# Adversarial review — round 1, spec

**Date**: 2026-09-17
**Subject**: `spec.md` (first draft) + `templates/validate-on-edit.sh`
**Panel**: `gpt-5.6-sol-high`, `cursor-grok-4.6-high`

**Caveat on this round.** The prompt file never reached the reviewers: a path guard rejected the command that would have written it, so both lanes ran with an empty question. `gpt-5.6-sol-high` returned an acknowledgement and nothing else — no finding, discard it. `cursor-grok-4.6-high` reviewed the staged files anyway and returned seven findings, all substantive. Round 2 carries the real prompt.

## Triage

| # | Finding | Verdict | Action |
|---|---|---|---|
| 1 | FR-006 makes a linked worktree validate the main checkout's copy of the file | **CONFIRMED in code** — `worktree_decision` guards only the exported-variable case (`validate-on-edit.sh:417`), and the comment at `:411` rests on the basename invariant this feature removes | Design change. Added FR-006b; moved the container-ownership check from Scope: OUT to IN; added US2 scenario 6 and SC-005a |
| 2 | Exit 1 cannot be classified under the constraints as written — code forbidden, message forbidden, probe forbidden by the no-second-stall edge case | **CONFIRMED** — the spec stated three constraints and no satisfying procedure | Design change. FR-001 now names two independent pieces of evidence; FR-001a bounds the probe by the existing budget instead of forbidding it |
| 3 | FR-004 treats daemon-down as a stale cache, so a faithful implementation re-resolves into a dead daemon | **CONFIRMED** | FR-004 rewritten to split two causes with different handling |
| 4 | The 125 table row is a `docker run` usage error, which the runner never performs; asserting it teaches the suite the wrong meaning | **CONFIRMED** | FR-009 now asserts 125 as unreachable rather than as a row; SC-001 counts seven situations, not eight |
| 5 | "Warn once" for a dead daemon contradicts per-service suppression, and a `nocontainer` key would later suppress a genuine missing-container warning | **CONFIRMED** | FR-004a added: one key per cause, stated against both failure shapes |
| 6 | FR-009's suite has nowhere to live — the runner has no self-test, and the scope forbids adding files | **CONFIRMED** | Scope widened to `tests/` under the same skill; that path collides with nothing the concurrent session holds |
| 7 | The resolved Compose name is neither normalised nor disambiguated between four possible Compose filenames | **CONFIRMED** — today's basename path lowercases and strips to `[a-z0-9_-]` (`validate-on-edit.sh:234`) | FR-006a added; FR-006 now names the file-precedence rule |
| — | SPECULATIVE: Colima and Docker Desktop sharing OrbStack's exit codes is assumed, not measured | **ACCEPTED as stated** | Assumption rewritten to say only OrbStack was measured, and why the two-evidence rule protects against a wording difference |

Seven findings, seven confirmed, two of them design-changing. No finding was rejected.
