# Canonical audit queries

These are the deterministic `yq` / `jq` one-liners referenced by `quickstart.md` and `data-model.md §7`. They are placed here so future tooling (e.g. a CI step or a `make audit-registry` target) can lift them verbatim.

## Q1 — Every asset has a `category`

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.assets[] | select(has("category") | not) | .path' asset-registry.yml
```

Expected: empty.

## Q2 — `common` is never a tag

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.assets[] | select(.tags[]? == "common") | .path' asset-registry.yml
```

Expected: empty.

## Q3 — Common bundle membership (count + paths)

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '[.assets[] | select(.bundles[]? == "common")] | {count: length, paths: map(.path) | sort}' \
  asset-registry.yml
```

Expected: `count: 20`, paths match `data-model.md §3.1`.

## Q4 — Folder ⇒ category for `rules/NN-…/`

See `quickstart.md §7`.

## Q5 — Tag-vocabulary diff (used vs declared)

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '[.assets[].tags[]?] | unique | sort' asset-registry.yml > /tmp/used.txt

docker run --rm -v "$PWD":/w -w /w ghcr.io/jqlang/jq:latest \
  -r '."$defs".tag.enum | sort | .[]' asset-registry.schema.json > /tmp/declared.txt

diff /tmp/used.txt /tmp/declared.txt
```

Expected: empty diff, or diff lines all annotated with `# reserved:` in the schema.

## Q6 — Tag enum size ≤ 45

```bash
docker run --rm -v "$PWD":/w -w /w ghcr.io/jqlang/jq:latest \
  '."$defs".tag.enum | length' asset-registry.schema.json
```

Expected: ≤ 45.

## Q7 — No `[NEW]` placeholder description left

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.["x-tag-descriptions"] | to_entries | map(select(.value | test("\\[NEW\\]"))) | .[].key' \
  asset-registry.yml
```

Expected: empty.

## Q8 — Asset count unchanged across the migration

```bash
git show HEAD~1:asset-registry.yml > /tmp/before.yml
BEFORE=$(docker run --rm -v "$PWD":/w -v /tmp/before.yml:/w/before.yml -w /w mikefarah/yq:4 '.assets | length' before.yml)
AFTER=$(docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 '.assets | length' asset-registry.yml)
[ "$BEFORE" = "$AFTER" ] && echo "OK: $BEFORE assets" || { echo "FAIL: $BEFORE -> $AFTER"; exit 1; }
```
