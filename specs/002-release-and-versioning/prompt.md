# Original Prompt

Create the following skills and command (in English):

1. **Skill `app-version-surface`** — Standardize how application components expose, transport, and display version metadata across the organization: frontend, backend, worker, gateway, embedded packages.

2. **Skill `semantic-release-js-ts-pipeline`** — Standardize release automation for JavaScript/TypeScript projects using semantic-release: version calculation, Git tags, release notes, npm publish policy.

3. **Command `/spec-release-and-versioning`** — Transform a versioning or release-related need into a full Speckit specification, covering version metadata contracts, UI display rules, CI/CD governance, and semantic-release policy.

## Key Decisions

- Standard display format: `<version>+<gitCommit>` (e.g. `2.4.1+5f2c9ab`)
- Mandatory fields per component: `component`, `displayVersion`, `version`, `gitCommit`, `buildTime`, `environment`
- Multi-component applications must aggregate component versions
- semantic-release recommended for JS/TS with conventional commits
- `@semantic-release/changelog` and `@semantic-release/git` not imposed by default
- Standard must be compatible with observability and support workflows
