# Contracts — Asset Registry Classification

This folder is the **acceptance test** of the schema refactor. Each fixture under `fixtures/` is a minimal YAML snippet purpose-built to either be accepted or rejected by `asset-registry.schema.json`.

The fixtures share the same top-level shape (`version`, `x-*-descriptions`, `assets`) — only the relevant section differs from the valid baseline, to keep the failure cause unambiguous.

## How to run

See `../quickstart.md §2`. Each `invalid-*.yml` MUST cause ajv to exit non-zero; each `valid-*.yml` MUST exit zero.

## Fixture catalog

### Positive fixtures (MUST validate)

| Fixture            | Proves                                                                                                  |
| ------------------ | ------------------------------------------------------------------------------------------------------- |
| `valid-minimal.yml`| Single asset with **only** the required fields (`path`, `type`, `category`).                            |
| `valid-full.yml`   | Single asset using all axes (`category`, `bundles`, `tags`, `description`) with valid values.            |

### Negative fixtures (MUST be rejected)

| Fixture                                  | Rejection trigger                                                          | Schema rule exercised                                            |
| ---------------------------------------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `invalid-missing-category.yml`           | `category` field omitted on an asset.                                       | `required: ["path","type","category"]` on `assetEntry`.          |
| `invalid-unknown-category.yml`           | `category: brain` (not in the 10-value enum).                               | `$defs.category.enum`.                                           |
| `invalid-array-category.yml`             | `category: [tools-and-configurations]` (array form forbidden).              | `$defs.category` is `string`, not array.                         |
| `invalid-unknown-bundle.yml`             | `bundles: [unicorn]`.                                                       | `$defs.bundle.enum` (v1 = `[common]`).                           |
| `invalid-unknown-tag.yml`                | `tags: [snake-oil]`.                                                        | `$defs.tag.enum`.                                                |
| `invalid-duplicate-tag.yml`              | `tags: [docker, docker]`.                                                   | `uniqueItems: true` on the `tags` array.                         |
| `invalid-common-as-tag.yml`              | `tags: [common]`.                                                           | `common` removed from `$defs.tag.enum` (FR-004, SC-003).         |
| `invalid-extra-property.yml`             | Unknown field `categories: [...]` (plural typo).                            | `additionalProperties: false` on `assetEntry`.                   |
| `invalid-folder-category-mismatch.yml`   | `path: rules/04-tools-and-configurations/4-foo.mdc` with `category: standards`. | Conditional `if/then` for folder prefix `rules/04-` ⇒ `tools-and-configurations`. |

Add a new fixture whenever you tighten the schema with a new constraint.
