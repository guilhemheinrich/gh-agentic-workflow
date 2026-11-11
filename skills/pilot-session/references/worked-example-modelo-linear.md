# Worked example — a Modelo roadmap tracked in Linear

One instantiation of the generic rules, kept close to the launch prompt it was
distilled from. Everything specific here (the `ws` CLI, `modelo-reviewer`, the
staging host, the `-pprod` namespaces) belongs to this setup, not to the skill.

## Launch prompt

```text
/pilot-session You are the pilot session of the Linear project <PROJECT>.
Key deadline: <MILESTONE / DATE>. You run at the root of modelo-workspace (`ws`);
the roadmap is that Linear project.
```

## How the generic rules were filled

| Generic rule | This setup |
|---|---|
| Tracker | Linear project; `.linear.json` + `linear-tracker` skill. Split into issues/sub-issues, PR link on the issue, status moved to In Review when the PR opens. Decisions that are not the pilot's: comment on the issue, people mentioned. |
| Branch naming | Linear `gitBranchName`, or `tt-NNNN-<slug>` |
| Target branch | `staging`, PR opened with `ws pr open` |
| References | `Linear: TT-NNNN` in the PR description, `Refs: TT-NNNN` in every commit |
| Repository constraints | Docker-only execution, repo CLAUDE.md and hooks, `specs/NNN-<slug>/brief.md` with `Scope: OUT` before the code; the `ws` dev stack stays up |
| Review gate | chosen for this project because the tooling was in place: 2–3 non-Anthropic models picked from the OpenRouter coding ranking, via `cursor-adversarial-review` (fallback `openrouter-adversarial-review`), then the host reviewer `modelo-reviewer` |
| Git-host news | `pr-watch`: `prw subscribe` on push, `prw wait` in the background; `prw subscribe --commit` for a direct push to `staging` |
| Merge | the pilot runs `ws pr merge` when the pipeline is green and `modelo-reviewer` gives the go. Non-blocking reserves: the pilot decides. Changes requested: back to the child. |
| Deployment follow-up | `prw` follows the post-merge pipeline of `staging` until deployment |
| Production | never without an explicit human GO |

## Verification child (staging, read-only)

- Browser: the Playwright MCP with SSO credentials on `hub.staging.modelo.fr`,
  session opened with
  `ENVIRONMENT=staging ~/code/MODELO_HUB/scripts/hub-playwright-session.sh`.
- Cluster: the `k8s-troubleshoot` skill (kubectl through Docker). Staging runs
  in the `-pprod` namespaces — e.g. `modelo-hub-pprod`,
  `modelo-bill-e-pprod`, `modelo-broker-pa-pprod`,
  `modelo-hub-calendar-pprod`, `modelo-hub-notifications-pprod`,
  `modelo-hub-iam-group-pprod`; take the ones of the project.
- Read-only: no ConfigMap edit, no rollout, no deletion; anything else in a
  "DevOps report" section. Never a secret or a token on screen.
- A ticket goes Done only with its staging proof: image tag, verbatim log
  lines, HTTP codes. Facts first, interpretation after.

## Cross-repository children

The pilot runs at the root of `modelo-workspace`, but most children work in a
service repository (`modelo-bill-e`, `modelo-broker-pa`, …). In Claude
Desktop such a child cannot be started from an event-driven turn (see
`harness-claude-desktop.md`): start those children on a user turn when
possible, or batch their proposal cards.
