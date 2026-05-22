# Quickstart — Validate and audit the asset registry

All commands run from the repo root, **Docker-only**, no host install required. Tested on `linux/amd64` and `arm64`.

## Prerequisites

- Docker 24+ with the Compose plugin (we don't use Compose here, just `docker run`).
- The two registry files at the repo root:
  - `asset-registry.yml`
  - `asset-registry.schema.json`

## 1 — Validate the registry against its schema

Single one-liner: convert YAML → JSON via `yq`, pipe into ajv-cli running in a one-shot Node container.

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 -o=json asset-registry.yml \
  > /tmp/asset-registry.json \
&& docker run --rm -v "$PWD":/w -v /tmp/asset-registry.json:/w/registry.json -w /w node:22-alpine \
  npx --yes ajv-cli@5 validate \
    --spec=draft2020 \
    -s asset-registry.schema.json \
    -d registry.json \
    --strict=false
```

Expected output: `registry.json valid`.
Exit code 0 → registry is valid.
Exit code ≠ 0 → ajv prints the JSON-pointer path and the failing constraint.

## 2 — Run every negative-fixture test

The spec ships invalid fixtures under `specs/013-asset-registry-classification/contracts/fixtures/invalid-*.yml`. Each MUST be **rejected** by ajv. Loop:

```bash
set -e
for fixture in specs/013-asset-registry-classification/contracts/fixtures/invalid-*.yml; do
  echo "=== $fixture (MUST fail) ==="
  docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 -o=json "$fixture" > /tmp/fixture.json
  if docker run --rm -v "$PWD":/w -v /tmp/fixture.json:/w/fixture.json -w /w node:22-alpine \
       npx --yes ajv-cli@5 validate --spec=draft2020 \
         -s asset-registry.schema.json -d fixture.json --strict=false 2>/dev/null; then
    echo "FAIL: $fixture was accepted, expected rejection."
    exit 1
  else
    echo "OK: rejected as expected."
  fi
done
echo "All negative fixtures rejected — schema is doing its job."
```

Mirror loop for the **positive** fixtures (`valid-*.yml`): they must validate, exit code 0.

## 3 — Audit: assets per category

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.assets | sort_by(.category, .path) | .[] | (.category + "\t" + .path)' \
  asset-registry.yml
```

Produces a tab-separated `<category> <path>` listing, deterministically sorted (FR-018, SC-009: byte-identical between two runs).

## 4 — Audit: bundle membership

```bash
# How many assets in each declared bundle?
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.assets | map(select(.bundles)) | group_by(.bundles[0]) |
   map({bundle: .[0].bundles[0], count: length, paths: [.[].path]})' \
  asset-registry.yml
```

Expect `common` count = **20** (see `data-model.md §3.1`).

## 5 — Audit: tag usage histogram + orphan / unused detection

```bash
# 5a — Tag usage histogram (descending)
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '[.assets[].tags[]?] | group_by(.) | map({tag: .[0], uses: length}) | sort_by(-.uses)' \
  asset-registry.yml

# 5b — Used set vs declared set
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '[.assets[].tags[]?] | unique | sort' asset-registry.yml > /tmp/used-tags.json

docker run --rm -v "$PWD":/w -w /w ghcr.io/jqlang/jq:latest \
  -r '."$defs".tag.enum | sort' asset-registry.schema.json > /tmp/declared-tags.json

# 5c — Orphans (used, not declared) — MUST be empty
diff <(cat /tmp/used-tags.json | docker run --rm -i ghcr.io/jqlang/jq:latest -r '.[]') \
     <(cat /tmp/declared-tags.json | docker run --rm -i ghcr.io/jqlang/jq:latest -r '.[]') \
     | grep '^<' || echo "No orphan tags."

# 5d — Unused declared tags (declared, never used) — should be empty modulo reserved
diff <(cat /tmp/used-tags.json | docker run --rm -i ghcr.io/jqlang/jq:latest -r '.[]') \
     <(cat /tmp/declared-tags.json | docker run --rm -i ghcr.io/jqlang/jq:latest -r '.[]') \
     | grep '^>' || echo "No unused declared tags."
```

## 6 — Audit: `common` never appears as a tag

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 \
  '.assets[] | select(.tags[]? == "common") | .path' asset-registry.yml
```

Expected output: empty. Any line printed is a SC-003 violation.

## 7 — Audit: folder ⇒ category for `rules/NN-…/` assets

```bash
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 '
  .assets[]
  | select(.type == "rule")
  | select(.path | test("^rules/[0-9]{2}-"))
  | select(
      (.path | test("^rules/00-") and .category != "architecture")
      or (.path | test("^rules/01-") and .category != "standards")
      or (.path | test("^rules/02-") and .category != "programming-languages")
      or (.path | test("^rules/03-") and .category != "frameworks-and-libraries")
      or (.path | test("^rules/04-") and .category != "tools-and-configurations")
      or (.path | test("^rules/05-") and .category != "workflows-and-processes")
      or (.path | test("^rules/06-") and .category != "templates-and-models")
      or (.path | test("^rules/07-") and .category != "quality-assurance")
      or (.path | test("^rules/08-") and .category != "domain-specific")
      or (.path | test("^rules/09-") and .category != "other")
    )
  | .path
' asset-registry.yml
```

Expected output: empty.

## 8 — Sanity: asset count unchanged by the migration

```bash
git show HEAD~1:asset-registry.yml > /tmp/before.yml
docker run --rm -v "$PWD":/w -v /tmp/before.yml:/w/before.yml -w /w mikefarah/yq:4 \
  '.assets | length' before.yml
docker run --rm -v "$PWD":/w -w /w mikefarah/yq:4 '.assets | length' asset-registry.yml
```

Both lines MUST print the **same** integer (NFR-004).

## 9 — Manual: VS Code autocomplete check (SC-010)

1. Open `asset-registry.yml` in VS Code with the official **YAML** extension installed.
2. Add a new entry; type `category: ` → autocomplete proposes the 10 categories.
3. Type `bundles: [` → autocomplete proposes `common`.
4. Type `tags: [` → autocomplete proposes the cleaned tag vocabulary.
5. Introduce an invalid extra field (`categories: foo`) → red squiggle inline.

Document the result (screenshot or short note) in the PR description.
