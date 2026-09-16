Ranked findings:

1. Critical — D6 can validate the wrong file. Design change.

The test checks only mount sources, not which mount supplies the validator’s container path (`plan.md:107-115`). Concrete counterexample:

- `/work/repo:/app`
- named volume `stale-src:/app/src`
- working directory `/app`
- validator reads `src/a.ts`

The first mount’s source is a parent of the edited host file, so the container passes. Linux’s deeper `/app/src` mount wins, so the validator reads the volume’s stale copy.

An even simpler failure is `/work/repo:/evidence` plus an image-created `/app`; the source test passes although the validator reads `/app`. Read-only mounts also pass but break fix-capable validators.

D6 must resolve the validator’s actual container path, choose the deepest matching mount destination, and map that mount back to its source. Source-only membership does not satisfy `spec.md:133-136`. The risk table considers only false refusal, not this more serious false acceptance (`plan.md:166-168`).

2. High — the nonce proves that `sh` started, not that the validator ran. Design change.

The marker is printed before command resolution and `exec` (`plan.md:47-56`). Therefore:

- Absent tool: nonce present, validator never ran.
- Alias: aliases are expanded while parsing; an alias named through `"$@"` is not expanded.
- Shell builtin: `exec "$@"` may execute the builtin in the shell rather than replace it. In Alpine, `umask` can succeed through the wrapper while direct `docker exec … umask` cannot find an executable.
- Executable text file without a shebang: direct OCI execution reports an exec-format error, while POSIX shells commonly handle `ENOEXEC` by interpreting the file. Example validator containing `exit 7`: direct invocation and wrapped invocation have different exit codes.
- Absent executable returns the shell’s 127 and diagnostic, not Docker’s original result.
- A command literally named `-a` can be parsed as an `exec` option by some shells.

The same ambiguity loses real findings in D2: a real validator may itself exit 126, 127, or 124. D2 unconditionally calls 126/127 “not installed” and 124 “budget” (`plan.md:63-71`), despite FR-003 requiring every executed non-zero validator to remain a violation (`spec.md:116-120`). Timeout needs independent evidence; command status 124 is not proof of timeout.

For ordinary external executables, stdin and working directory are preserved: `sh -c` reads its program from argv and the marker does not consume stdin. Environment is not identical, however: a shell can add or alter `PWD`, `SHLVL`, and shell-specific state. Signal preservation also has a race: after printing the nonce but before successful `exec`, a timeout or signal can terminate the shell; the plan then claims a validator ran when it did not.

3. High — nonce transport and stripping are not robust. Design change.

The nonce is written to container stdout. The validator may immediately write stderr. Those streams are separately transported by Docker and merged only at the outer redirect used by the budget wrapper (`validate-on-edit.sh:206-230`), so stderr can appear before the nonce. The marker is not guaranteed to be an output prefix.

If the Docker client is killed while transporting output, the captured marker can be complete, partial, or absent. D2 specifies only “nonce present, killed by budget”; it omits timeout before a complete nonce arrives (`plan.md:63-71`).

Stripping can corrupt a real finding. If validator output contains the exact nonce, removing all occurrences deletes diagnostic text; if that was its only output, D2 downgrades it to “failed without diagnostics.” The risk table’s claim that collision yields “a duplicate finding, never a lost one” is backwards (`plan.md:164-166`). At minimum, the design needs explicit framing, exact one-occurrence removal, and defined handling for partial markers and cross-stream ordering.

4. High — D2 hides status-only validators. Design change.

A concrete validator is `grep -q forbidden "$F"` or `cmp -s expected "$F"`: non-zero communicates the finding and intentionally prints nothing. D2 turns that into an infrastructure-style warning (`plan.md:63-71`), so it is not counted as a violation or handled by retry logic. The current classifier’s violation bookkeeping is only entered for `_VIOLATION` (`validate-on-edit.sh:311-346`, `584-600`).

The safe default is a synthesized violation such as “validator exited N without diagnostics.” If exit-only status is not considered a finding, the routing table needs explicit metadata saying so; it cannot be inferred.

5. High — D5 has no cache invalidation model and contradicts the required Compose resolution. Design change.

The runner is a fresh process per hook invocation. A useful “session” cache therefore must be persisted, but current state is keyed only by project root, not agent session or Compose environment (`validate-on-edit.sh:160-167`). D5 does not say what invalidates:

- `.env`, Compose files, or `COMPOSE_FILE` changes;
- a changed `COMPOSE_PROJECT_NAME`;
- a consumer resolver override;
- two concurrent sessions in one checkout with different Compose environments;
- a cached live container after the project configuration changes.

A normal second physical checkout is safe only if the cache remains under the existing root-keyed state directory. That requirement is unstated.

Also, running `docker compose config` with the hook’s present environment cannot recover a `-f …` list used when the stack was started. Research explicitly left file selection and `COMPOSE_FILE` unsettled (`research.md:86-89`), while the plan claims explicit lists are honoured “by construction” (`plan.md:95-105`). This also conflicts with the written-resolution requirement in `spec.md:131-133`.

With no Compose file, only basename-labelled containers are discoverable; containers started with an invisible `-p` remain missed, as the plan partially acknowledges.

6. Medium — D3 is ambiguous for scaled or overlapping containers. Design change.

A Compose service can have two running IDs, one equal to the cached ID and one different. Raw `docker ps` then matches both the “same id” and “different id” rows (`plan.md:75-86`). Existing `lookup_cid` hides this by taking an arbitrary first line (`validate-on-edit.sh:239-242`), making recovery nondeterministic.

“Different ID” also does not prove stack recreation; it may be another replica. D3 should treat output as a set and define candidate selection, including D6 verification for every candidate.

7. Medium — D7’s floor is undefined and cannot be represented reliably by the current clock. Design change.

Research measured roughly 28–34 ms for one probe (`research.md:24-35`), not an upper bound from which a guaranteed floor can be derived. The runner tracks only integer seconds (`validate-on-edit.sh:197-201`), so a subsecond reserve is impossible and a one-second reserve consumes one third of the default budget.

If `floor >= remaining`, the runner must stop before invoking anything and emit the budget warning. Passing zero to GNU `timeout` can disable timeout, while the watchdog path behaves differently. The floor needs a stated value, clock precision, clamping rule, and explicit “insufficient remainder” branch.

8. Low — D8 is feasible, but underspecified. Test-plan wording change.

It need not become a second implementation. The suite can make an exact, one-site textual mutation in a copied runner, assert exactly one replacement occurred, and then run the same black-box cases. If it instead contains code that independently decides which executions are infrastructure, it duplicates the classifier.

D8 should name the mutation site/operator and require failure when zero or multiple sites match (`plan.md:123-129`). The underlying mutation-testing decision is sound.

Unsupported preference

D5’s session cache is the clearest preference presented without research support. `research.md` neither measures repeated resolution nor defines a cache lifetime or invalidation strategy; its Compose section ends with unresolved questions (`research.md:78-89`). The claimed 103 ms Compose measurement appears only in the plan (`plan.md:34-38`), not in `research.md`.

D7’s floor is also unmeasured, but unlike the cache it is driven by the budget-safety requirement.

Regressions versus the current runner

For some consumers this plan is worse because:

- A distroless container with a working validator but no POSIX shell works with direct `docker exec` today and fails entirely after D1. An optional doctor check does not remove that regression (`plan.md:56-58`, `plan.md:162-164`).
- Shell builtins, shebangless files, shell-added environment, and `exec` option parsing alter observable validator behavior.
- D7 shortens the effective validation budget, potentially timing out validators that currently finish.
- D6 can reject valid named-volume or synchronized-volume setups, while also accepting shadowed stale files.
- A persistent D5 cache can continue using an obsolete Compose name after configuration or environment changes.

D4 is sound: `fix` and `check` share `_run`/`exec_in`, so invalidation belongs there (`validate-on-edit.sh:289-315`). D9 cannot be verified within the staged boundary.
