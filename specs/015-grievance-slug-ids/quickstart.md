# Quickstart — verify merge-safe grievance identifiers by hand

**Phase 1** · 2026-08-26 · branch `015-grievance-slug-ids`
**Status**: walked end to end on 2026-08-26. Every value below is observed output, not a prediction.

Ten minutes, no fixtures to build. Every command runs in the container the skill
documents, per the Docker-only rule. Run it from a scratch directory, never
against this repository's own ledger.

```bash
S=/tmp/grv-demo
G() { docker run --rm -v "$S:/repo" -v "<repo>/skills/grievances:/skill:ro" -w /repo python:3.12-alpine python3 /skill/scripts/grievances.py "$@"; }
```

Replace `<repo>` with the absolute path to this repository.

---

## 1 — Set up a scratch repository

```bash
rm -rf "$S" && mkdir -p "$S/specs" && cd "$S" && git init -q .
G init --file /repo/specs/GRIEVANCES.md
git add -A && git commit -qm base
```

## 2 — Two branches, two findings that share their opening words

This is the case that breaks a naive design: both descriptions start with the
same four significant words, so a name built only from the words that fit would
be identical.

```bash
git switch -qc dev-a
G add --file /repo/specs/GRIEVANCES.md --severity high --impact "cannot scale the worker alone" \
     --short "release pipeline npm token expires after ninety days"
git commit -qam a

git switch -q main && git switch -qc dev-b
G add --file /repo/specs/GRIEVANCES.md --severity medium --impact "2FA silently breaks publishing" \
     --short "release pipeline npm token bypasses two factor auth"
git commit -qam b
```

**Observed**:

```
GRV-release-pipeline-npm-token-9c23 declared (high, 2026-08-26)
GRV-release-pipeline-npm-token-96f0 declared (medium, 2026-08-26)
```

Same four readable words, different discriminator. Before this change both
branches allocated `GRV-0001`.

## 3 — Merge, and confirm the tool refuses a conflicted file

```bash
git switch -q main
git merge -q --no-edit dev-a     # clean
git merge --no-edit dev-b        # CONFLICT, expected
G list --file /repo/specs/GRIEVANCES.md
```

**Observed** — a refusal that names the fix, not a misparse:

```
error: /repo/specs/GRIEVANCES.md: unresolved merge conflict (4 marker line(s), first: '<<<<<<< HEAD')
resolve the conflict first — keep both sides, then run: grievances.py rebuild
```

## 4 — Resolve by keeping both sides, then regenerate

```bash
grep -vE '^(<<<<<<< |=======$|>>>>>>> )' specs/GRIEVANCES.md > /tmp/kb && mv /tmp/kb specs/GRIEVANCES.md
G rebuild --file /repo/specs/GRIEVANCES.md   # → rewritten
G rebuild --file /repo/specs/GRIEVANCES.md   # → already normalized
G list --file /repo/specs/GRIEVANCES.md
```

**Observed**: both entries listed, the generated table carrying two rows with
live anchors, and the second `rebuild` reporting `already normalized` — the
idempotency check.

## 5 — Finish the lifecycle

```bash
G resolve GRV-release-pipeline-npm-token-9c23 --file /repo/specs/GRIEVANCES.md \
  --commit 1a2b3c4d --note "worker split out"
G check --file /repo/specs/GRIEVANCES.md --strict
```

**Observed**: `v specs/GRIEVANCES.md — 1 open, 1 resolved`, then
`1/1 repo(s) compliant`.

## 6 — Confirm the refusals

```bash
G add --file /repo/specs/GRIEVANCES.md --short "slow" --severity low --impact x
G add --file /repo/specs/GRIEVANCES.md --short "a distinct finding here" --severity low --impact x --id GRV-Worker-API
G add --file /repo/specs/GRIEVANCES.md --short "a distinct finding here" --severity low --impact x --id GRV-worker
G add --file /repo/specs/GRIEVANCES.md --short "a distinct finding here" --severity low --impact x --id GRV-0099
```

Four refusals, each naming the rule: too few significant words; uppercase not
permitted; one segment where 2 to 5 are required; the legacy form is never
minted.

Then the `--force` contract, which changed:

```bash
G add --file /repo/specs/GRIEVANCES.md --severity low --impact x \
     --short "release pipeline npm token bypasses two factor auth"
```

→ refused, pointing at `bump`, and stating that a genuinely distinct finding
needs `--force AND --id`.

```bash
G add --file /repo/specs/GRIEVANCES.md --severity low --impact x --force \
     --short "release pipeline npm token bypasses two factor auth"
```

→ still refused: `--force needs --id`, because deriving would produce the same
identifier. Adding `--id GRV-token-second-case` succeeds.

## 7 — Confirm the integrity refusals

Each of these is a way the ledger used to lie or to become unusable.

```bash
printf '<<<<<<< HEAD\n' >> specs/GRIEVANCES.md && G list --file /repo/specs/GRIEVANCES.md
# → refuses, names the conflict. Remove the line before continuing.
```

Then, by hand in the file: rename one marker's identifier to `GRV-worker` in all
three places (marker, JSON `id`, closing marker) and run `G list`. It must
**refuse**, naming the unusable id. Before this change that entry vanished from
the tables while its text stayed in the file.

Duplicate one whole detail block verbatim and run `G list`. It must refuse with
`appears twice` **and** name the recovery: keep one block, `bump` the survivor,
`rebuild`.

Finally, add a bare `=======` line inside a grievance's prose and run `G list`.
It must **succeed** — that is legal markdown, not a conflict marker.

## 8 — Confirm the identifier is frozen

Edit an entry's `short` field inside its JSON header, then:

```bash
G rebuild --file /repo/specs/GRIEVANCES.md && G list --file /repo/specs/GRIEVANCES.md
```

The table shows the new description under the **old** identifier. Re-derivation
would produce a different name; nothing performs it.

## 9 — Run the test suite

From this repository, not the scratch directory:

```bash
docker run --rm -v "$PWD:/repo" -w /repo/skills/grievances/scripts python:3.12-alpine python3 -m unittest -v
```

56 tests.

---

## Cleanup

```bash
rm -rf /tmp/grv-demo
```
