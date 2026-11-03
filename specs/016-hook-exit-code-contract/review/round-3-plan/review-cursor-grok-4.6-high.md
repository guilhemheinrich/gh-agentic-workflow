D4 and D9 are sound. D2’s third row (nonce present + real output, including a daemon-shaped first line) is the right verdict. The rest below would change the design, not the wording.

### D6’s parent-source rule accepts a container that does not read the file the agent wrote
- location: `specs/016-hook-exit-code-contract/plan.md:110`
- trigger: any mount whose **source** is an ancestor of the edited file, regardless of destination or shadowing
- consequence: a pass/fail is reported on a different inode. That is the defect D5 makes reachable (`plan.md:12`), and this rule does not close it.

The test never looks at **which mount actually covers the container path**. Docker uses longest-prefix destination. Concrete shapes that **pass D6 and still read the wrong file**:

1. **Deeper mount shadows a shallower one.** Bind `/checkout -> /app` plus `/other-branch/src -> /app/src`. Edited file is `/checkout/src/main.ts`. `/checkout` is a parent, so the candidate is accepted. The process running in `/app` reads `/other-branch/src/main.ts`.
2. **Named volume over a subpath.** `.:/app` plus `node_modules:/app/node_modules` (or `srcvol:/app/src`). Parent bind matches; the validator reads the volume.
3. **Copy, not a bind, plus an ancestor mount.** `COPY . /app` and `-v $HOME:/host:ro`. Edited file is under `$HOME/proj/...`. `$HOME` is a parent, so D6 accepts. The linter’s cwd is `/app`, the image copy.
4. **Nested linked worktree.** Main checkout `/proj` mounted at `/app`; worktree at `/proj/worktrees/foo`. `/proj` is a parent of the edited file. After D5 the labels match (`name:` in the Compose file). The container lints `/proj/src/...`, not the worktree file.

Read-only of the **same** bind is not a counterexample: `:ro` still reads that host path.

`VALIDATE_WORKTREE=run` (`plan.md:112`) bypasses the check on purpose. Nested worktrees are not that opt-in. Today they often fail lookup (basename ≠ `name:`) and stay unvalidated — safe. D5+D6 turns that into a **false pass**. Worse than the current runner.

The restated `worktree_decision` (`plan.md:114`) is defined in terms of this same rule, so it inherits the nested-worktree accept.

---

### D1 puts the nonce on stdout with no newline, then `exec`; classification and stripping are unspecified for the streams the runner actually captures
- location: `specs/016-hook-exit-code-contract/plan.md:48-54`
- trigger: stderr-first validators; a `sh` that does not flush stdio before `exec`; budget truncation mid-nonce
- consequence: a ran validator is classified as “nonce absent” (finding dropped, maybe cache dropped), or a real diagnostic is eaten by stripping

`with_budget` already merges streams on the host:

```214:214:skills/static-validation-hooks/templates/validate-on-edit.sh
    "$TIMEOUT_BIN" "$left" "$@" >"$BUDGET_OUT" 2>&1
```

The wrapper prints the nonce to **container stdout**, with **no newline**, then `exec`s. Research left this unset (`research.md:62`). The plan treats it as settled.

**Where the nonce lands**

| Condition | Where the bytes go | Strip-from-front | Search-anywhere then delete |
|---|---|---|---|
| Happy path, `sh` flushes | Prefix of `BUDGET_OUT`, glued to the first diagnostic | OK | OK |
| Validator writes stderr first; CLI emits stderr before flushed stdout | Nonce in the **middle** (or after the first finding) | Absence → **infrastructure, finding lost** | Presence kept, but a mid-line delete corrupts the finding if it collides |
| `printf` then `exec` without fflush (stdio fully buffered on the docker pipe) | Userspace buffer **discarded on exec**; nonce never appears; validator output does | Absence → **finding lost** | Same |
| Budget kills during the first write | Partial nonce at start of `BUDGET_OUT` | Presence test fails; remainder looks like a finding **or** an outage | Partial prefix left in the agent-visible text |
| Line-oriented strip (`sed 1d`, `grep -v`) | First line is `NONCE<path>:<line>: ...` | **Entire first finding dropped** | Same |

The risk table’s claim that a nonce collision “would produce a duplicate finding, never a lost one” (`plan.md:167`) is false for the first four rows of that table.

**Does the wrapper change observable validator behaviour?** Yes, in these concrete cases:

- **Exit code / “not found”.** `docker exec <cid> ruff` failing is an OCI 127 (`research.md:13`). After the wrap, `sh` **did** start, the nonce **is** present, and `exec`’s 127 is a shell “not found”. D2 then calls it a wiring warning (`plan.md:67`). That is intended for a missing tool. It is a behaviour change for a **missing `sh`**: OCI 127, nonce absent, D3 “same id / unclassified” instead of “tool not installed”.
- **Stdin.** `printf` does not read stdin. A profile sourced because the image sets `ENV` / `BASH_ENV` **can**, and today’s `docker exec <tool>` never sources it. That is a container that changes stdin, PATH, or cwd only because of D1.
- **Signals.** After `exec`, same PID, same `timeout` → `docker exec` kill path as today. The window before `exec` is real but tiny: a budget kill there yields nonce-maybe-absent + 124.
- **Cwd / env.** Unchanged unless that profile runs. `SHLVL`/`_` may now be set; almost no linter cares.
- **`exec "$@"` and builtins / aliases / absent.** Correct **relative to today’s `docker exec`**, which also does not use a shell: `cd`/`source`/`eval`/`alias` already cannot be the tool. Absent tool: nonce printed, 127, D2 wiring — that part is right. It is **incorrect** for a consumer whose “tool” is a shell builtin **and** who would have needed `sh -c` without `exec`; the plan claims the validator “keeps the process, its exit code, its stdin and its signal behaviour” (`plan.md:52`) as if this were identical to a direct exec. For distroless / no-`/bin/sh` / seccomp that allows the linter binary and not `sh`, it is not: those containers validate **today** and become outages under D1.

---

### D3’s four `docker ps` rows are not a partition of `lookup_cid`
- location: `specs/016-hook-exit-code-contract/plan.md:77-84` vs `skills/static-validation-hooks/templates/validate-on-edit.sh:239-243`
- trigger: two replicas (`--scale`, or two containers with the same project+service labels); a hung daemon; `lookup_cid` reused as-is
- consequence: a live stack is treated as a dead daemon (session-wide mute), or as a recreate (wrong retry)

`lookup_cid` is not “one `docker ps`”:

```239:243:skills/static-validation-hooks/templates/validate-on-edit.sh
lookup_cid() {
  docker ps -q \
    --filter "label=com.docker.compose.project=$(compose_project)" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null | head -n1
}
```

`set -o pipefail` is on (`validate-on-edit.sh:34`). `2>/dev/null` discards the only non-rc signal. `head -n1` closes the pipe after one line.

**Matches two rows at once.** Cached id is replica A (still running). `head -n1` returns replica B. That is “succeeds, a different id” (recreated → update cache, retry) **and** “the same id is alive”. The plan compares against one unordered id, not “is the cached id in the running set”.

**SIGPIPE looks like row 1.** Two matching containers: `docker ps` often exits 141 after `head` closes. Row 1: “fails → daemon unreachable or client refused → warn once for the session, **do not resolve again**” (`plan.md:81`). A healthy daemon plus `--scale api=2` can mute **all** services for the rest of the `STATE_DIR` lifetime. That is worse than today’s 125 arm, which never fires.

**Matches none of the four.** `docker ps` hung (daemon wedged, not refused): killed by the budget, rc 124, not “fails / empty / other id / same id”. D7 is supposed to cover “no budget for a second call”; D3 still presents the table as exhaustive (`plan.md:77`).

Daemon-down with empty stdout also matches row 1 and row 2 if anyone tests emptiness without rc — `lookup_cid` as written returns empty stdout and a lost rc inside `cid="$(lookup_cid …)"`. Reusing that function cannot implement the table.

FR-007’s recreate path is row 3, not row 2; that split is fine **if** the id comparison is against the set. “Retry once, then classify normally” (`plan.md:83`) can re-enter row 3 unless a retry flag exists.

---

### D5 caches a Compose name with no invalidation, asks Compose in violation of FR-011, and can parse the wrong `"name"`
- location: `specs/016-hook-exit-code-contract/plan.md:96-104`, `specs/016-hook-exit-code-contract/spec.md:132`
- trigger: compose file edited mid-session; `configs:` / nested `"name"`; no compose file at `PROJECT_ROOT`; two checkouts
- consequence: the silent-miss D5 exists to fix, reintroduced by cache; or a wrong project name with more authority than today’s basename

**What invalidates the cache?** Nothing in the plan except “the session”. Session here is `STATE_DIR`, i.e. `cksum(PROJECT_ROOT)` under `$TMPDIR` (`validate-on-edit.sh:164-166`), which already outlives the agent. A cid miss does not refresh the name.

- **Edits `name:` (or `.env`, or `COMPOSE_FILE`) mid-session, recreates the stack:** lookup keeps filtering the old label, docker ps is empty, nocontainer warning once, silence. Same shape as the original defect.
- **Two checkouts:** different `PROJECT_ROOT` → different `STATE_DIR`, so the name cache does not cross checkouts. What **does** cross is the declared `name:`: both resolve to `broker-pa`, `lookup_cid | head -n1` returns one container, D6 may reject the other checkout’s running stack. Compose already collides on a hard-coded `name:`; the plan does not iterate candidates (`plan.md:110` is “a candidate”).
- **No compose file, containers exist:** step 3 falls back to basename (`plan.md:100`). Same as today if the stack was started with `-f` elsewhere or only `docker run`. Diagnostic can show the fallback; runtime still misses. Not worse than today, and not a fix.

**FR-011** requires a **written filename order**, “not by a pointer at Compose’s own behaviour”. D5 is exactly that pointer (`plan.md:38`, `plan.md:104`). That is a frozen-spec miss, not a wording nit. `docker compose config --format json` also does not give you a safe `.name` through this runner’s extractor: `extract_json_string` takes the **first** `"name"` (`validate-on-edit.sh:58-80`). A `configs:` (or any nested `"name"` serialized first) is a wrong project name. Research used the Compose query as a probe (`plan.md:38`); it did not measure this parser.

---

### D7’s floor is an unmeasured preference and makes the hot path strictly tighter
- location: `specs/016-hook-exit-code-contract/plan.md:116-118`
- trigger: default `VALIDATE_BUDGET_S=3` (`validate-on-edit.sh:37`); remaining time `<` the floor; two `check`s on one edit
- consequence: clean runs get less time than today; a still-runnable validator is skipped; findings that fit in the leftover window are lost

The floor’s magnitude is not in `plan.md` or `research.md`. The probe is ~30 ms and **only after** a failed provenance check (`research.md:34`, `research.md:58`). Reserving that on **every** `exec_in` taxes the path SC-005 says must stay zero-cost extra.

When **floor > remaining**: if the implementation skips the validator to “protect” the probe, a 50 ms `ruff` is dropped so a 30 ms `docker ps` that will not run on success can run. If it starts the validator anyway, the floor did not reserve anything. The plan states both goals and defines neither.

FR-010/FR-022/FR-023 (budget warning text, temp file leak at `validate-on-edit.sh:210-211`) do not require a floor. They require “if you cannot decide, warn, and unlink the file”.

---

### D2’s empty-output row hides exit-code-only checkers — and is undefined until “empty” is post-strip
- location: `specs/016-hook-exit-code-contract/plan.md:69`
- trigger: `grep -q`, `test`, `cmp -s`, or any wrapper that exits non-zero with no bytes; also the nonce-only capture
- consequence: either a warning that conceals the only signal those tools have, or a **violation whose payload is the nonce**

Faithful to FR-004 (`spec.md:119`): that class is a warning, not a violation. Do not reopen the spec. The **plan** still has a hole: the nonce is output (`plan.md:49`). If emptiness is tested **before** strip, the third row (`plan.md:68`) always wins and the agent sees a finding that is the nonce (or the nonce glued to whitespace). If after strip, `grep -q` is hidden as “failed without diagnostics”. Today that class is **silence** (`validate-on-edit.sh:342`); D2 is louder, not more accurate.

---

### D8’s mutant is specified as a result, not as an operation the suite can perform without cloning `check()`
- location: `specs/016-hook-exit-code-contract/plan.md:128`
- trigger: the suite tries to “classify every exit 1 as infrastructure” after D2 has deleted that branch
- consequence: a sed that restates the decision table is a second classifier; a sed that stops matching goes green without injecting the fault

The runner cannot be sourced (it runs on load, `validate-on-edit.sh:539-600`). The suite must copy the file and exec it. A one-line fault injection in **that copy** (`(( rc == 1 )) && infra; return` at the top of `check`) is testable in bash and is not a second implementation. Anything that re-encodes D2’s table in the test is. The plan does not choose.

---

### Q9 — preference presented as a measurement: D7, then D6’s parent heuristic
`research.md` has no budget floor, no floor vs `VALIDATE_BUDGET_S`, no temp-file measurement. D7 is a preference.

D6 is the close second. Phase 0 claims a “mount inventory of a live container” (`plan.md:34`). `research.md` has no such inventory — only “the identity test must rest on the mount … and the plan owes a canonicalisation rule” (`research.md:72-74`). Parent-or-equal **source** is not in the research note.

D1’s exact `printf`/`exec` wrapper was explicitly **not** settled (`research.md:62`) and is written as if it were. D5’s session-lifetime name cache is also unmeasured; asking Compose at all is measured (103 ms) and still contradicts FR-011.

D4 (move invalidation into `exec_in`) and D9 (port after green) are spec sequencing, not fake measurements. Sound.

---

### Q10 — what this plan makes worse for a consumer who is fine today

1. **Nested worktree or shadowed bind** — false pass on the other tree’s file (D5+D6). Today: often no match, unvalidated.
2. **`--scale` / two labels-matched containers** — D3 SIGPIPE → session-wide “daemon dead”, **no validation at all**.
3. **Distroless / no `sh` / seccomp that allows the linter and not a shell** — D1 turns a working `docker exec <tool>` into unclassified outage.
4. **Every edit’s budget** — D7 floor shortens the 3 s cap that two `check`s already share; more 124 warnings, more dropped findings.
5. **Compose `name:` change without a new `STATE_DIR`** — D5 cache; stack recreated, hook still points at the old project.

The current runner’s bug is **noisy** (daemon text as a violation). Several of these replacements are **silent wrongness** or **total mute**. That is a worse contract for the consumers the spec is trying to stop from ignoring the hook.

---

**D4** — sound: invalidation belongs in `exec_in` so `fix` cannot leave a dead cid for `check` (`plan.md:90-92`, FR-017).

**D9** — sound as a sequenced port (`plan.md:130-132`).
