# apiconv — dependencies

Everything apiconv needs, split by where it runs. apiconv uses no MCP server.

## Host (your machine)

| Tool | Used by | Purpose |
|---|---|---|
| `docker` | `apiconv.sh` | Builds the image on first use or after a source edit, then runs every command in it. |
| `sh`, `shasum`, `cut`, `sed`, `cat` | `apiconv.sh` | Hash the tool sources into the image tag (`apiconv:<12 hex>`) and print the usage text. |
| `sed`, `cmp`, `diff`, `mktemp`, `cp` | `selftest.sh` | Copy the fixture, mutate output files, compare two conversions. |

No host Node, npm or Python. `shasum` ships with macOS and Git Bash; on a bare Linux, use the `perl` package or
alias it to `sha1sum`.

## Image (`node:22-alpine`, built from `scripts/Dockerfile`)

| Package | Version | Used by | Purpose |
|---|---|---|---|
| `jq` (apk) | Alpine current | `runtime-check.sh` | Filters Postman items by the plan regex; reads newman and bru JSON reports. |
| `postman-collection` | 5.3.1 | `apiconv.mjs` | Builds Postman URLs; loads the output back in `verify`. |
| `ajv-draft-04` | 1.0.0 | `apiconv.mjs` | Validates collections against the Postman v2.1 schema (a draft-04 schema). |
| `ajv-formats` | 3.0.1 | `apiconv.mjs` | Registered on the validator; the cached v2.1 schema uses no `format` keyword today, so it guards a future schema only. |
| `ajv` | 8.20.0 | — | Peer of `ajv-draft-04` and `ajv-formats`. |
| `@usebruno/lang` | 0.41.0 | `apiconv.mjs` | Serializes `.bru` files in `convert`; parses them back in `verify`. |
| `@usebruno/cli` | 4.3.0 | `runtime-check.sh` | Provides `bru run`. |
| `newman` | 6.2.3 | `runtime-check.sh` | Runs the Postman collection. |

Versions are pinned in `scripts/package.json` and locked in `scripts/package-lock.json` (`npm ci --omit=dev`).

## Network

| Host | When | Purpose |
|---|---|---|
| Docker Hub | First `docker build` | Pulls `node:22-alpine`. |
| `dl-cdn.alpinelinux.org` | First `docker build` | Installs `jq`. |
| `registry.npmjs.org` | First `docker build` | `npm ci`; the lockfile resolves only to this registry. |
| `schema.getpostman.com` | Only if `scripts/schemas/postman-collection-v2.1.0.json` is missing | Downloads the Postman v2.1 schema. The file is committed, so normal runs stay offline. |
| The API under test | `runtime-check.sh` only | newman and bru send the planned requests, once each. |

`convert` and `verify` make no network call once the image exists.
