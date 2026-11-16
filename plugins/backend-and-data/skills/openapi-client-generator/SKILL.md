---
name: openapi-client-generator
description: >-
  Generate and keep up to date API client SDKs from an OpenAPI or Swagger
  specification with pinned, reproducible tooling (Redocly, hey-api
  openapi-ts, openapi-generator, oapi-codegen, Kiota). Use when creating or
  regenerating a client from openapi.yaml, openapi.json or swagger.yaml,
  choosing a generator per language, or adding a CI check that generated
  clients are in sync with the spec.
---

# OpenAPI client generation

A deterministic recipe. Commands live in `templates/Makefile.snippet` and
`templates/ci-step.yml`; copy and trim them.

1. **Spec intake.** Merge refs with `redocly bundle openapi.yaml -o
   build/openapi.bundled.yaml` and lint (`redocly lint`, or Spectral) before
   anything else. A Swagger 2.0 spec is converted first with openapi-generator
   (`-g openapi-yaml`, which emits OpenAPI 3), then re-linted and diffed by
   eye; generate from the converted file.
2. **One tool per target.**
   - TypeScript: `@hey-api/openapi-ts` (exact pin, the project is 0.x and
     breaks between minors), or openapi-generator `typescript-fetch`.
   - Go: `oapi-codegen`, run as `go tool oapi-codegen` (declared by
     `go get -tool github.com/oapi-codegen/oapi-codegen/v2/cmd/oapi-codegen`).
     OpenAPI 3.x only: convert Swagger 2.0 first.
   - Python, Java, C#: openapi-generator.
   - Microsoft ecosystem: Kiota (`kiota generate -d <spec> -l CSharp -o ...`).
3. **Pin everything.** Docker tag (`openapitools/openapi-generator-cli:v7.27.0`,
   never `latest`), exact npm versions (no `^`), the `tool` directive and
   version in `go.mod`, Kiota in a dotnet tool manifest. Unpinned generators
   produce surprise diffs.
4. **Output** goes to `generated/<lang>/` and is never hand-edited. Put custom
   behavior in wrappers or custom templates outside that folder. List options
   with `config-help -g <generator>` before adding `--additional-properties`.
5. **One entry point:** `make generate-client` (lint, bundle, generate all
   targets). Humans and CI run the same command.
6. **CI:** run `make generate-client`, then `git diff --exit-code generated/`.
   A non-empty diff means the committed client is stale (or the generator
   drifted: check the pins).

Mounting on Windows or CI: Docker needs the repo mounted (`-v "$PWD:/local"`)
and paths relative to `/local`.
