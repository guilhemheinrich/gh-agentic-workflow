---
name: apiconv
description: >-
  Convert Insomnia v4 export collections into Postman (Collection v2.1) and Bruno (.bru) collections, then prove
  the three agree. `convert` is deterministic (two runs give byte-identical files) and aborts on any construct it
  cannot map; `verify` parses the output back with each client's own library (postman-collection SDK plus the
  official JSON schema, @usebruno/lang) and requires deep equality with the Insomnia source, request by request,
  with secrets redacted in diffs; `runtime-check.sh` sends a read-only plan of requests through newman and bru
  against a live API and requires the same HTTP status from both. Docker-only, nothing needs host Node. Use when
  shipping an API collection to people who use another client, converting an Insomnia collection to Postman or
  Bruno, checking collection parity across clients, or generating .bru files. Triggers on "Insomnia", "Postman",
  "Bruno", ".bru", "convert collection", "collection parity", "newman", "bru run".
tags:
  - tooling
  - testing
  - verification
  - docker
---

# apiconv — Insomnia collections to Postman and Bruno, verified

apiconv takes a folder of Insomnia v4 exports and writes the same requests for Postman and Bruno. It then
reads its own output back with each client's parser and fails on the first field that differs.

It was first used on 2026-10-29 to ship per-consumer API bundles (Insomnia, Postman, Bruno and a
`VERIFICATION.txt` per zip).

## When to use

- A consumer of your API uses Postman or Bruno, and your reference collection lives in Insomnia.
- You must show that three client collections hold the same requests, not just claim it.
- You want `.bru` files generated rather than hand-written.

Do not use it for Insomnia v5 YAML exports, request folders or pre-request scripts (see *Limits*).

## Input layout

```text
<bundle-dir>/
  insomnia/
    00-<identity>.insomnia.json   # identity: environments holding the credentials
    01-<collection>.insomnia.json # one collection workspace per file, 01..09
    02-<collection>.insomnia.json
```

- Collection files match `0[1-9]*.insomnia.json`. The file name minus `.insomnia.json` is the collection slug:
  `01-demo-items.insomnia.json` gives slug `01-demo-items`.
- The identity file holds one environment per identity. Its values must be plain strings, no templates.
  Example: environment `demo` in `scripts/fixtures/demo/insomnia/00-identity-demo.insomnia.json` holds
  `client_id`, `client_secret`, `api_token`.
- Each collection has exactly one base environment. Its templated values (`{{ _.x }}`, `{% now %}`,
  `{% uuid %}`) become computed variables, rendered at send time.

## One command

```bash
skills/apiconv/scripts/apiconv.sh bundle <bundle-dir> <identity-file-name> <identity-env-name> [<plan-file>]
```

`bundle` runs `convert`, then `verify`, then the runtime check when a plan file is given. It writes
`<bundle-dir>/postman/`, `<bundle-dir>/bruno/` and reports under `<bundle-dir>/.apiconv/`. It exits non-zero on
any static mismatch or any runtime `DIFF`.

The two halves run on their own too:

```bash
skills/apiconv/scripts/apiconv.sh convert <bundle-dir> <identity-file-name> <identity-env-name>
skills/apiconv/scripts/apiconv.sh verify  <bundle-dir> <identity-file-name> <identity-env-name>
```

The launcher builds a `node:22-alpine` image tagged by the hash of its sources. Editing a tool file rebuilds
it on the next run; nothing else does. Dependencies are pinned by `package-lock.json`. The full list of host
tools, image packages and network calls is in `references/dependencies.md`; read it only when installing,
debugging a build, or running offline.

`APICONV_LABEL` prefixes the Postman environment names. Unset, the environment of identity `demo` is named
`staging — demo`; with `APICONV_LABEL="Acme"` it is `Acme staging — demo`. The Postman environment id derives
from that name, so the label changes the id as well.

## What each check proves

1. **Static round trip** (`apiconv.mjs verify`). The Postman collections validate against the official v2.1
   JSON schema, cached in `scripts/schemas/`. The `postman-collection` SDK and `@usebruno/lang` load the output.
   Both are mapped back to the neutral model and compared field by field with the Insomnia source. A diff on a
   field named `secret`, `password` or `token` names the field, never the value. Example report line:
   `FAIL  bruno roundtrip   01-demo-items (3 requests)  /requests/2/headers/0/name: "X-Request-Id" != "X-Trace-Id"`.
2. **Determinism** (`convert` twice). Ids are sha256-derived from names, JSON is written with a fixed key
   order, so `diff -r` between two runs is empty.
3. **Runtime parity** (`runtime-check.sh`). The planned requests run against the live API through `newman` and
   `bru`. Each must get the same HTTP status in both: `SAME postman 200  bruno 200   1. List items`.

### The runtime plan: read-only requests only

The plan file holds one `collection-slug|request-name-regex` line per collection. The regex is `grep -E` on the
request name. Blank lines and `#` comments are ignored.

```text
# scripts/fixtures/demo/runtime-plan.txt
01-demo-items|^1\.
```

**The plan must select only requests that do not write.** `runtime-check.sh` sends every request it selects,
twice (once per client), against the environment's real host. A POST that creates an invoice would create two.
In the fixture, request `2. Create item` is a POST, so the plan keeps request 1 only.

## Declared losses

- Insomnia's `when-expired` re-send of a response-tag source request has no equivalent: re-run that request.
- An empty JSON body on a GET is dropped. No Content-Type header is sent either way.
- Bruno has no description on headers and form fields: those go to the request Docs, after an
  `<!-- apiconv:field-notes -->` marker.
- Postman scripts store values as collection variables; Bruno scripts store them in the selected environment.

## Stages (staging, prod)

A collection may carry stage sub-environments under its Base Environment. Every collection must then hold the
same stages, each with the same keys in the same order. Every identity environment named after a stage (`prod`)
or after a stage and a holder (`staging — alice`) becomes one target. Each stage needs at least one.

- A stage key with the same value in every stage joins the collection variables.
- Each target becomes one Postman `00-environment-<target>` file shared by all collections, and one Bruno
  `environments/<target>.bru` per collection. `<target>` is the slug of the identity name: `staging-alice`.
- Two collections that give one stage key two different values abort the run: one Postman environment cannot
  hold both.
- The last argument names the target the runtime check uses (`staging-alice`).

A collection without stages yields one Postman environment named after the identity and one Bruno environment
named `staging`.

## Self-test

```bash
skills/apiconv/scripts/selftest.sh
```

On the synthetic fixture in `scripts/fixtures/demo/`, it checks convert + verify, a byte-identical second
conversion, and three hand-made mutations that `verify` must reject: a Postman URL path, a Postman query
string, and a `.bru` header name. The fixture uses only reserved `.test` hosts and fake credentials.

## Shipping a bundle

`templates/README.bundle.md` is a consumer-facing README with `<PLACEHOLDER>` fields. Fill it per bundle; never
paste a credential into it. Ship `.apiconv/report.verify.txt` as `VERIFICATION.txt` beside it.

## Limits

- Input is the Insomnia **v4 export JSON** (what the app's *Export* produces). Insomnia v5 YAML is not read yet.
- Not supported, and the run aborts on them: request folders, pre-request scripts, path parameters, auth other
  than none/basic/bearer, bodies other than JSON and form-urlencoded, non-default request settings, template
  tags other than `{% now 'millis' %}`, `{% now 'custom', 'yyyy-MM-dd' %}`, `{% uuid 'v4' %}` and the
  `{% response 'body' … 'when-expired' %}` tag.
- After-response scripts may use `insomnia.response.code`, `insomnia.response.json()`,
  `insomnia.environment.set(` and `insomnia.environment.get(` only.
- The runtime check compares HTTP status codes, not response bodies.

## Implementation status

**Fully implemented.** Verified on 2026-10-30 in Docker: `selftest.sh` passes (all static checks, empty
`diff -r`, three mutations rejected with exit 1). Regression on a real 5-collection, 36-request bundle: with
`APICONV_LABEL` set to the original product label, the Postman and Bruno output is byte-identical to the
bundle shipped on 2026-10-29.

`bundle` with the fixture plan was run offline: the plan selected request 1 only in both clients, and the
unreachable host gave `DIFF postman ERR  bruno error  1. List items` with exit 1, as it must.

**Not verified here:** `runtime-check.sh` against a live API (the fixture host does not resolve), and the
staged path on the fixture (it has no stages; the staged code is the version that built the stage bundles, except
the environment label, now `APICONV_LABEL`-driven).
