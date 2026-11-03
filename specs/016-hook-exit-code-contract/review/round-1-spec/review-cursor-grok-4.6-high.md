The staged spec is a draft for a contract the runner still does not implement. The defects below are in the spec’s own constraints, and in regressions that implementing it against this runner would introduce. The bugs the spec already names (`125` vs `1`, two-of-four Compose sources) are not restated.

### FR-006 makes worktree `auto` validate the wrong tree
- location: `specs/016-hook-exit-code-contract/spec.md:106` (FR-006, US2.2); `skills/static-validation-hooks/templates/validate-on-edit.sh:413` and `:417`
- trigger: linked worktree of a repo whose project name comes from compose `name:` or from project `.env` `COMPOSE_PROJECT_NAME`, with `VALIDATE_WORKTREE=auto` and that variable not exported
- consequence: today `compose_project()` uses the worktree basename, `lookup_cid` finds nothing, and the hook warns. After FR-006 both checkouts resolve the same Compose name, so the worktree execs into the main stack’s bind mount and can pass or fail on a file the agent did not edit. `worktree_decision` only skips when the variable is exported, so the `.env` source US2.2 requires walks around the guard. The check that would reject a container whose working directory is another checkout is explicitly out of scope (`spec.md:137`).

### Exit 1 cannot be classified under the constraints as written
- location: `specs/016-hook-exit-code-contract/spec.md:101` (FR-001); `:90`; `:93`; `:49` (US1.3)
- trigger: `docker exec` returns 1 — measured for a stopped/removed container, an unreachable daemon, *and* a validator that found issues
- consequence: FR-001 forbids classifying on the exit code alone; the edge case forbids classifying on the daemon-error prefix alone (a linter can emit that text and still be a finding). The remaining discriminator is a second Docker probe. That probe, when the daemon is down, *is* the “re-resolution … second stall” the edge case forbids. An implementer who probes fails the stall rule; one who does not will either dress daemon errors as findings (US1.1) or drop real exit-1 findings (US1.3 / US3.2). The spec never states a procedure that satisfies all four.

### FR-004 treats daemon-down as a stale cache
- location: `specs/016-hook-exit-code-contract/spec.md:104` (FR-004); `:23` (daemon unreachable → 1); `:93`
- trigger: cached cid, Docker daemon unreachable; first `docker exec` returns 1 (same code as a dead container)
- consequence: FR-004 says discard the cache and re-resolve once. Re-resolve is `lookup_cid` → `docker ps`, another blocking daemon call. The spec does not define “attributable to the cached container” vs “attributable to Docker”, so a faithful FR-004 implementation violates the no-second-stall edge case on the measured daemon-down row.

### The measured 125 row is not a runner situation and collides with synthetic 125
- location: `specs/016-hook-exit-code-contract/spec.md:25`; `:27`; `:109` (FR-009); `:83` (US3.1)
- trigger: a maintainer implements FR-009/US3.1 against every table row, including `docker run --nonsense-flag` → 125
- consequence: the runner never calls `docker run`. It *does* return 125 of its own (`lookup_cid` empty, docker missing — `validate-on-edit.sh:268`, `:299`). The spec already says `docker exec` never returns 125 and that the 125 arm is only those synthetic returns. Asserting the table’s 125 row either tests an unreachable CLI usage error or teaches the suite that 125 means “CLI usage error” rather than “no container”. SC-001’s “eight measured failure situations” counts this row.

### “Warn once” for a dead daemon contradicts per-service suppression
- location: `specs/016-hook-exit-code-contract/spec.md:51` (US1.4); `:111` (FR-011); `skills/static-validation-hooks/templates/validate-on-edit.sh:330`
- trigger: daemon down, routing table has two services; agent edits a file for each
- consequence: US1.4 wants one “validation is unavailable” warning, then silence. FR-011 wants per-service and per-cause keys. The only existing key for this path is `nocontainer-$_SVC`. The spec never names a daemon-down cause, so one of US1.4 or FR-011 will fail on a two-service table, and a nocontainer warning will also suppress a later genuine missing-container warning for that service.

### FR-009 cannot be placed without breaking scope or the stated harness assumption
- location: `specs/016-hook-exit-code-contract/spec.md:109`; `:134`; `:147`
- trigger: implementer tries to ship the suite this feature requires
- consequence: scope allows changing only `templates/validate-on-edit.sh`. This file has `--dry-run` / `--check` / `--doctor` and no self-test. The assumption says extend the plugin copy’s harness and not add a second one; that copy is a different repository (FR-012). Satisfying FR-009 here means introducing the harness the assumption forbids, or leaving this runner without the suite SC-007 says both copies must pass.

### Compose name resolution omits sanitization and file identity
- location: `specs/016-hook-exit-code-contract/spec.md:106`; `:65`; `skills/static-validation-hooks/templates/validate-on-edit.sh:234`
- trigger: `name:` or `.env` `COMPOSE_PROJECT_NAME` with uppercase, dots, or other characters Compose strips; or more than one of `compose.yml` / `compose.yaml` / `docker-compose.yml` / `docker-compose.yaml`
- consequence: today’s basename path lowercases and keeps only `[a-z0-9_-]`, which is what container labels carry. US2.1 says “resolves the declared name” with no sanitization step and no rule for which Compose file’s `name:` wins. A literal read then feeds `lookup_cid` a string no container is labelled with — the same silent miss US2 exists to fix.

SPECULATIVE: Colima/Desktop sharing OrbStack’s `docker exec` codes (`spec.md:142`) is assumed, not measured in these files.
