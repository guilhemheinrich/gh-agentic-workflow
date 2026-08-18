---
name: openrouter-adversarial-review
description: >-
  Get a spec, a diff or a design reviewed by a model from a different lineage
  than the one that wrote it, through OpenRouter, from the command line. One key
  reaches GPT, Kimi, Gemini, DeepSeek and the rest, so a second opinion costs a
  string change rather than a new billing relationship. Covers the user-level key
  setup on fish, bash/zsh and Windows, how to write a prompt that refutes instead
  of flatters, which context actually improves a review and what it costs (a
  measured tier table), and ships `llm-ask.sh` — a composable one-shot client with
  repeatable `-f` file attachment and a cached model catalogue (prices, context
  windows and republished benchmark scores) that lets you name a reviewer by
  capability — `--top 5 --by coding`, `-m @top --exclude-vendor anthropic` —
  instead of by slug. Use when asking another model to attack your work, picking a
  reviewer without knowing model names, reviewing a spec or a diff outside the
  agent that produced it, setting up an OpenRouter key, or debugging a gateway
  that answers HTTP 200 with an error body.
tags:
  - llm
  - quality
  - security
  - shell
  - tooling
  - verification
---

# OpenRouter Adversarial Review

The model that wrote a diff is the worst judge of it: it shares every assumption
that produced the bug. A review by a *different lineage* surfaces what no amount
of self-review will — and through OpenRouter it is one HTTP POST, one key, and a
model slug you can swap in a string.

That is the whole point of this skill. Everything else here serves it: the key
setup, the prompt that asks for refutation instead of praise, and the discipline
of sending the context that helps rather than all the context there is.

```text
  spec + plan + diff ──┐
  changed files ───────┼──▶ llm-ask.sh ──▶ OpenRouter ──▶ GPT · Kimi · Gemini · …
  signatures ──────────┘        │                              │
                                │                              ▼
                    -f blocks, retries,            candidate findings on stdout
                    cost estimate, exit codes      (to verify — never a verdict)
```

## 1. What is in this bundle

| File                              | Role                                                  |
| --------------------------------- | ----------------------------------------------------- |
| `scripts/llm-ask.sh`              | The client. Routing, retries, pricing, extraction.    |
| `templates/openrouter-key.fish`   | Key setup — fish, macOS and Linux.                    |
| `templates/openrouter-key.sh`     | Key setup — bash and zsh, macOS and Linux.            |
| `templates/openrouter-key.ps1`    | Key setup — Windows, user-scope environment variable. |
| `templates/aliases.example`       | Optional pinned choices — `@top` replaces most of it.  |

## 2. Setup: the key, once per machine

Get a key at <https://openrouter.ai/keys>, then run the script for your shell.
All three are **idempotent** — they create the file if it is missing, leave an
existing key untouched, never duplicate a line — and all three leave a
`PASTE_YOUR_KEY_HERE` placeholder for you to replace.

**fish** (macOS, Linux) — writes `~/.config/fish/conf.d/openrouter.fish`, chmod 600:

```bash
fish ~/.claude/skills/openrouter-adversarial-review/templates/openrouter-key.fish
```

**bash or zsh** (Linux, macOS) — writes the key to `~/.config/openrouter/key.env`
at chmod 600 and adds one `source` line to each rc it finds. The key stays in its
own file so that a dotfiles repo never swallows it:

```bash
bash ~/.claude/skills/openrouter-adversarial-review/templates/openrouter-key.sh
```

**Windows** — sets a persistent *user-scope* environment variable, which every
new process inherits, including Git Bash and GUI-launched agents that read no
shell profile:

```bash
powershell -ExecutionPolicy Bypass -File "$env:USERPROFILE\.claude\skills\openrouter-adversarial-review\templates\openrouter-key.ps1"
```

Then set the real value and open a **new** terminal — existing ones keep the old
environment:

```bash
setx OPENROUTER_API_KEY "sk-or-v1-…"
```

`llm-ask.sh` is a bash script needing `curl` and `jq`, so on Windows it runs under
**Git Bash or WSL**. Git Bash inherits Windows user variables, so `setx` covers
it. WSL does not — inside WSL, use `openrouter-key.sh` instead.

Finally, put the client on your PATH:

```bash
install -m 755 ~/.claude/skills/openrouter-adversarial-review/scripts/llm-ask.sh ~/.local/bin/llm-ask.sh
```

### Naming, and the one trap

`OPENROUTER_API_KEY` is the canonical name — one export serves every tool that
talks to OpenRouter. `LLM_OPENROUTER_API_KEY` overrides it when you want a key
scoped to this script alone.

The trap is the opposite direction. **Never point a provider-owned base URL at
OpenRouter.** `ANTHROPIC_BASE_URL` is already exported inside a Claude Code
session — setting it to a gateway to "try Kimi" reroutes Claude Code's own
traffic. Likewise, exporting `ANTHROPIC_API_KEY` flips Claude Code from your
subscription to per-token API billing. This script therefore ignores
`ANTHROPIC_BASE_URL` and `OPENAI_BASE_URL` outright and warns in `--doctor` when
it finds them set; reroute it alone with `LLM_BASE_URL` or `--base-url`.

### Making the key visible to an agent

`~/.config/fish/conf.d/*.fish` is read by fish and nothing else, and an agent
harness runs its shell tool under **bash**:

| How the agent was launched            | Does it see the key?                     |
| ------------------------------------- | ---------------------------------------- |
| `claude` from your terminal           | Yes — inherited from the parent process. |
| Desktop app, IDE extension, cron, CI  | Only if a bash-readable file declares it.|
| Windows, any launcher                 | Yes — `setx` is process-wide.            |

On macOS and Linux, the bash/zsh setup above is what makes it work for both. As a
last resort the `env` block of **user-scope** `~/.claude/settings.json` works
regardless of shell — but that is a plaintext secret in a JSON file, so never in
a project-scope `.claude/settings.json`, which gets committed.

## 3. Verify before spending anything

```bash
llm-ask.sh --doctor
```

Dependency paths, which keys are visible (never their values), and the
environment hazards above. Costs nothing.

```bash
llm-ask.sh --list-models gpt
```

Live model slugs. Also free, and keyless — the OpenRouter `/models` endpoint is
public, which is why `--dry-run` can price a call before your key even works.
Slugs drift constantly; this is the only trustworthy source for them.

```bash
llm-ask.sh --doctor --ping -m gpt
```

One real token, to prove the key actually authenticates.

## 4. The review itself

The prompt does the work. Ask for a verdict and you get flattery; ask for
refutation and you get findings. Reviewing a spec against its plan:

```bash
llm-ask.sh -m gpt-pro -o review-gpt.md -f specs/012-tax-rounding/spec.md -f specs/012-tax-rounding/plan.md -s @adversarial.md "Review this specification against its plan."
```

Reviewing an implementation against the spec it claims to satisfy — diff on
stdin, artefacts attached:

```bash
git diff main...HEAD | llm-ask.sh -m gpt-pro -o review-gpt.md -f specs/012-tax-rounding/spec.md -s @adversarial.md "Does this change implement the specification?"
```

A system prompt worth keeping in `adversarial.md`:

```text
You are reviewing work produced by another AI. Your job is to find what it got
wrong, not to summarise or praise it.

Report only defects you can tie to a specific location: cite file:line from the
FILE blocks provided, state what breaks, and name the input or condition that
triggers it. Prefer one demonstrated defect over five plausible ones.

Look for: requirements that are untestable as written, contradictions between
spec and implementation, missing failure cases, and assumptions held silently.

Label anything you cannot ground in the provided text as SPECULATIVE. Do not
review files outside the blocks provided. If you find nothing, say "no defect
found" rather than inventing something.
```

Three rules for consuming the output, each learned the expensive way:

- **It is a list of candidates, not a verdict.** A confident third-party model is
  wrong about as often as a confident first-party one. Every finding gets checked
  against the code before it changes anything.
- **Keep it out of the loop that produced the code.** Feeding the review straight
  back into the authoring agent produces an argument between two models instead
  of a decision by a person.
- **Pick a different lineage on purpose.** Reviewing Claude's output with Claude,
  or GPT's with GPT, buys much less than the price suggests. `-m kimi` and
  `-m gemini` exist for this reason.

## 5. How much context to send

`-f` embeds a file as a labelled block, repeatable and order-preserving. The user
message is assembled in a fixed order — **instruction, then `-f` files, then
stdin** — so the same invocation always produces the same bytes:

```text
INSTRUCTION (the positional argument)

===== FILE: specs/012-tax-rounding/spec.md =====
…contents…
===== END FILE: specs/012-tax-rounding/spec.md =====

----- BEGIN INPUT -----
…stdin, the diff…
----- END INPUT -----
```

The labels are not decoration: they are what lets you demand `file:line`
citations and get a navigable answer.

There is no upload in a `chat/completions` call — "attaching" a file means
embedding its text, and `-f` embeds **text only**. A PDF or a screenshot needs
multimodal content parts (`{"type": "image_url", …}`), out of scope here. For a
markdown spec, text is better anyway: cheaper, lossless, no OCR in the path.

Building a list means a loop, and **the shell matters**:
`$(printf ' -f %s' *.md)` word-splits in bash but arrives as one argument in zsh
and fish, where the script rejects it with `unknown option`.

```bash
set ctx; for f in specs/012-*/**.md; set -a ctx -f $f; end; llm-ask.sh -m gpt-pro $ctx "Review this spec set."
```

That is fish. In bash it is an array:

```bash
ctx=(); while IFS= read -r f; do ctx+=(-f "$f"); done < <(find specs/012-* -name '*.md'); llm-ask.sh -m gpt-pro "${ctx[@]}" "Review this spec set."
```

### What a review actually needs, and what it costs

Measured on a real ~6 MB Go service (paths anonymised), reviewing one feature
commit of 7 changed files against its spec. **Only the token column is quoted
here**: token counts describe your content and stay true, whereas prices move —
three models changed rate within one hour during development — so pricing them is
the catalogue's job, not this document's.

| Tier                                                 | tokens | fits a 1M window? |
| ---------------------------------------------------- | ------ | ----------------- |
| **T1** spec + plan + tasks + diff                    | 12k    | yes               |
| **T2** + the 7 changed files **in full**             | 33k    | yes               |
| **T3** + every function signature in the repo (1361) | 54k    | yes               |
| **T4** + every source file in full (122)             | 403k   | yes               |
| **T5** the whole versioned repo                      | 1.55M  | **no**            |

To turn any of those into money at today's rate, ask the catalogue (§6):

```bash
llm-ask.sh --dry-run -m @top --max-tokens 8000 -f specs/012-tax-rounding/spec.md "Review this spec."
```

Or price an arbitrary token count against every top model at once:

```bash
jq -r --argjson tok 54000 '[.models[]|select(.ii!=null)|select(.id|test(":batch")|not)]|sort_by(-.ii)[:5][]|"\(.id)\t$\((.in*$tok/1000000*10000|round)/10000) for \($tok) tokens in"' ~/.cache/llm-ask/models.json
```

**T3 is the sweet spot, and money is not why.** T4 fits a 1M window for a couple
of dollars at any plausible rate. The reason to stop before it is that recall
degrades as the window fills and — more prosaically — *a reviewer given the whole
repo reviews the whole repo*. You asked about one change and get fifteen remarks
on files you never touched. The context boundary is the review boundary.

Each tier earns its place for a distinct reason:

- **Spec and plan** — without the intent, the model can only judge syntax.
- **The diff** — what changed.
- **Changed files in full** — the highest-value single addition. A hunk without
  its enclosing function is the main source of false positives: the model flags an
  uninitialised variable that was initialised twenty lines above the hunk.
- **Signatures of everything else** — the *shape* of the application without its
  flesh. On the measured repo, 21k tokens for 1361 signatures against 370k for the
  bodies: roughly 95% of the context benefit for 6% of the price. This is the
  answer to "but then it has no idea what the rest of the app does".
- **Conventions** (`CLAUDE.md`, `rules/`) — otherwise house style is reported as a
  defect.

To widen past the changed files without drifting, add *callers*, not everything:
`spaghetti-compass impact <file> -c . --json` yields the reverse-impact set.

### Price the call first

`--dry-run` resolves and prices everything, and sends nothing:

```bash
llm-ask.sh --dry-run -m gpt-pro --max-tokens 8000 -f specs/012-tax-rounding/spec.md "Review this spec."
```

```text
provider : openrouter
model    : openai/gpt-5.6-sol
url      : https://openrouter.ai/api/v1/chat/completions
key      : missing
timeout  : 600s per attempt, 2 retr(y|ies)
prompt   : 27871 chars (~6967 tokens, estimate)
cost     : ~USD 0.0174 in (@ USD 2.50/M) + up to USD 0.1200 out (8000 tok @ USD 15.00/M)
context  : 6967 of 1050000 tokens (0.7%)
payload  : { … }
```

The real output writes those amounts with a dollar sign. This document spells
them `USD` on purpose: a `$` followed by a digit inside a SKILL.md is replaced by
the Nth argument when the skill is invoked as a slash command — an amount like
USD 0.0174, written with a dollar sign, renders as the first word the user typed.
Never put a dollar sign directly before a digit in a skill body.

Token counts are `chars / 4` — optimistic for source code, so read them as a
floor and expect ~20% more on a diff-heavy prompt. Past the window it becomes a
hard warning:

```text
context  : 181173 of 163840 tokens (110.6%)
WARNING  : prompt exceeds this model context window
```

### Aliases

Model slugs drift; `templates/aliases.example` maps stable short names onto them
in `~/.config/llm-ask/aliases`, so a slug change is one line rather than a sweep
through every script and prompt. `gpt`, `gpt-pro`, `kimi`, `gemini`, `deepseek`
are defined there with their measured context window and price. Trailing comments
on a line are stripped; verify a slug with `--list-models` before trusting it.

## 6. Choosing the reviewer without knowing model names

Model slugs are the worst thing to hardcode: they churn, and remembering which
one is currently strong is not a skill worth having. OpenRouter republishes
third-party benchmark scores in the model catalogue, under
`.benchmarks.artificial_analysis` — `intelligence_index`, `coding_index`,
`agentic_index` — so "give me the smart ones" is a query, not a memory exercise.

```bash
llm-ask.sh --top 5 --by coding --exclude-vendor anthropic
```

```text
top 5 by coding_index — one per vendor, from 2026-08-18T09:59:47Z

MODEL                                   SCORE    IN $/M   OUT $/M    CONTEXT
openai/gpt-5.6-sol                       77.4       2.5        15    1050000
x-ai/grok-4.6                            76.8         2         6     500000
moonshotai/kimi-k3                       76.2         3        15    1048576
google/gemini-3.7-flash                  76.1     0.375     1.875    1048576
qwen/qwen3.8-max                         71.8         2         6    1000000
```

And to skip the lookup entirely, `@top` resolves against that same ranking:

```bash
git diff main...HEAD | llm-ask.sh -m @top --by coding --exclude-vendor anthropic -f specs/012-tax-rounding/spec.md -s @adversarial.md "Does this implement the spec?"
```

`--exclude-vendor anthropic` is the flag that matters most here: reviewing
Claude's output, you want everything *except* Claude. `@top:2`, `@top:3` walk down
the ranking, which is how you fan out a panel:

```bash
for n in 1 2 3; do llm-ask.sh -m @top:$n --exclude-vendor anthropic -f specs/012/spec.md "Attack this spec." -o review-$n.md; done
```

Four ranking rules, all deliberate, all in the script rather than in your head:

| Rule                              | Why                                                                 |
| --------------------------------- | ------------------------------------------------------------------- |
| One model per vendor              | A panel needs distinct lineages, not three checkpoints of one family.|
| `:batch` variants dropped         | The cheaper rate comes with batch delivery; a review loop wants now. |
| `:free` and image/audio dropped   | Rate-limited, or off-task.                                          |
| Unscored models dropped, not last | Silence beats a guess at capability.                                |

`--min-context K` adds a floor when the review context is large. Note the scores
are **third-party benchmarks republished by OpenRouter**, not measurements of your
task: treat them as a defensible default, not as truth. Only 140 of 412 models
carry them.

### The catalogue cache

Nothing about prices or scores is hardcoded — it is fetched once and cached:

| Aspect         | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| Location       | `${XDG_CACHE_HOME:-~/.cache}/llm-ask/models.json` (`LLM_MODELS_CACHE`) |
| Freshness      | Refetched when older than `LLM_CACHE_TTL_H` hours (default 24)      |
| Force refresh  | `llm-ask.sh --models-refresh`                                      |
| Size           | ~78 KB distilled, from a ~675 KB source payload                     |
| Source         | `GET https://openrouter.ai/api/v1/models`, no key required           |

It is not stored inside the skill directory on purpose: the skill is deployed by
`cp -Rf` to several agent directories, so a cache living there would be clobbered
on every install and diverge per copy.

The distilled shape, should you want to query it directly:

```bash
jq -r '.models[] | select(.ci != null) | [.id, .ci, .in, .out, .ctx] | @tsv' ~/.cache/llm-ask/models.json | sort -k2 -nr | head
```

```json
{ "fetched_at": "…", "fetched_epoch": 1786…, "count": 412,
  "models": [ { "id": "openai/gpt-5.6-sol", "ctx": 1050000, "in": 2.5, "out": 15,
                "ii": 60.9, "ci": 77.4, "ag": 57.8, "reasoning": true } ] }
```

`in` and `out` are dollars per **million** tokens. `--doctor` reports the cache
path, its age against the TTL, and how many models carry benchmark scores.

### Doing it with curl alone

Everything above is one public endpoint. To price a model, or rank by score,
without this script:

```bash
curl -sS https://openrouter.ai/api/v1/models | jq -r '.data[] | select(.id=="openai/gpt-5.6-sol") | {ctx: .context_length, in: (.pricing.prompt|tonumber*1e6), out: (.pricing.completion|tonumber*1e6), bench: .benchmarks.artificial_analysis}'
```

```bash
curl -sS https://openrouter.ai/api/v1/models | jq -r '[.data[] | select(.benchmarks.artificial_analysis.intelligence_index != null) | select(.id|test(":batch|:free")|not)] | sort_by(-.benchmarks.artificial_analysis.intelligence_index)[:10][] | "\(.benchmarks.artificial_analysis.intelligence_index)\t\(.id)"'
```

### The rest of the public API, probed

| Route                                     | Key? | What it gives                                            |
| ----------------------------------------- | ---- | -------------------------------------------------------- |
| `GET /api/v1/models`                      | no   | Everything: pricing, context, `benchmarks`, `supported_parameters`, `knowledge_cutoff`. |
| `GET /api/v1/models?category=programming`  | no   | A 20-model shortlist curated for coding. Handy, opaque ordering. |
| `GET /api/v1/models/{author}/{slug}/endpoints` | no | Per-provider endpoints for one model — routing and per-provider price. |
| `GET /api/v1/providers`                   | no   | Provider list and policies.                              |
| `GET /api/v1/credits`                     | yes  | Your remaining balance.                                  |
| `GET /api/v1/models/user`                 | yes  | Models your key can reach.                               |

`/api/frontend/*` routes that the website itself uses return 404 from outside;
there is no public leaderboard endpoint beyond the `benchmarks` field above.

## 7. Script reference

Every flag, and the environment variable that presets it:

| Flag                  | Env             | Default        | Effect                                                          |
| --------------------- | --------------- | -------------- | --------------------------------------------------------------- |
| `-m, --model ID`      | `LLM_MODEL`     | —              | Slug, or an alias from the alias file. Required.                 |
| `-p, --provider NAME` | `LLM_PROVIDER`  | inferred       | `openrouter` \| `openai` \| `anthropic` \| `custom`. §11.        |
| `-f, --file PATH`     | —               | —              | Embed a file as a labelled block. Repeatable. §5.               |
| `--top N`             | —               | —              | Rank the N best-scored models, one per vendor, and exit. §6. |
| `--by METRIC`         | —               | `intelligence` | Ranking metric: `intelligence` \| `coding` \| `agentic`.     |
| `--exclude-vendor V`  | —               | —              | Drop a vendor from the ranking. Repeatable. Your own lineage.|
| `--min-context K`     | —               | `0`            | Require at least K tokens of context window when ranking.    |
| `--models-refresh`    | —               | —              | Refetch the catalogue now, ignoring the TTL. Alone: fetch and exit. |
| `-s, --system TEXT`   | —               | —              | System prompt; `@path` reads it from disk.                       |
| `--base-url URL`      | `LLM_BASE_URL`  | per provider   | Endpoint root. The only supported way to reroute. §2.            |
| `-t, --temperature N` | —               | **unset**      | Sent only when given; reasoning models reject non-default.       |
| `--max-tokens N`      | —               | 4096 anthropic | Output cap. Omitted entirely elsewhere unless given.             |
| `--timeout S`         | `LLM_TIMEOUT_S` | `600`          | Wall-clock per attempt. See below — do not shrink it blindly.    |
| `--retries N`         | `LLM_RETRIES`   | `2`            | Retries on 429/5xx/network only, exponential backoff.            |
| `-o, --out FILE`      | —               | stdout         | Write the completion to a file instead.                          |
| `--json`              | —               | off            | Raw response body, for scripted extraction.                      |
| `--dry-run`           | —               | off            | Resolve, price and print — call nothing. §5.                     |
| `--doctor`            | —               | —              | Dependencies, visible keys, env hazards. Costs nothing.          |
| `--ping`              | —               | —              | With `--doctor`: one real 1-token call to prove auth.            |
| `--list-models [F]`   | —               | —              | OpenRouter slugs, substring-filtered. Needs no key.              |
| `-v, --verbose`       | `LLM_VERBOSE=1` | off            | Alias resolution, routing, prompt size, token usage — on stderr. |
| `-h, --help`          | —               | —              | Usage summary.                                                   |
| `--version`           | —               | —              | Script version.                                                  |

`-m` also accepts a **selector** instead of a slug: `@top`, or `@top:N` for the
Nth of the ranking, resolved through `--by` and `--exclude-vendor`. §6.

Five environment variables have no flag: `LLM_ALIAS_FILE` (default
`${XDG_CONFIG_HOME:-~/.config}/llm-ask/aliases`), `LLM_MODELS_CACHE` (default
`${XDG_CACHE_HOME:-~/.cache}/llm-ask/models.json`), `LLM_CACHE_TTL_H` (default
`24`), `LLM_WARN_CHARS` (default `400000` — the assembled-prompt size that
triggers a stderr warning), and `OPENROUTER_API_KEY` /
`LLM_OPENROUTER_API_KEY` from §2.
The completion goes to **stdout**; diagnostics, warnings and usage go to
**stderr**. That is what makes the script composable — `> review.md` captures the
review and nothing else.

| Exit | Meaning                                                              |
| ---- | -------------------------------------------------------------------- |
| 0    | Answer on stdout.                                                    |
| 1    | Bad invocation.                                                      |
| 2    | Environment: missing `curl`/`jq`, missing key, no model.             |
| 3    | Provider refused, or answered with nothing usable.                   |
| 4    | Wall-clock budget exhausted.                                         |

An empty completion is exit 3, never a silent success — a refusal and a
zero-token answer must not read like a clean review.

### Timeouts: never let the clock kill a paid answer

The default is **600s per attempt**, deliberately generous. A reasoning-tier model
handed 50k tokens of review context routinely spends several minutes before the
first byte arrives, and a timeout that fires early is the worst outcome available:
the input has already been billed and you have nothing.

Exit 4 means exactly that. There is no retry on timeout — retrying a call that was
probably still working would double the bill — so the fix is to raise `--timeout`,
not to rerun it unchanged. Worst case is bounded at `timeout × (retries + 1)`, so
the defaults cap a pathological run at 30 minutes. Shrink `--timeout` only for
short interactive questions where a fast failure beats a slow answer.

## 8. Failure modes

| Symptom                                    | Cause                                                       |
| ------------------------------------------ | ----------------------------------------------------------- |
| HTTP 200 with `{"error": …}` in the body   | Gateway-level failure. Status alone is not a verdict.        |
| 400, "unsupported parameter"                | A reasoning-tier model rejecting `temperature`. Drop `-t`.   |
| 401 / 403                                   | Key rejected, or no access to that model.                    |
| 402                                         | Out of credits on the account behind the key.                |
| 404 on a model id                           | Slug drifted. `--list-models`.                               |
| 413, or a context-length error              | Too much context. Scope it down; do not raise the cap.       |
| 429                                         | Rate limited. The script retries twice with backoff.         |
| Empty text, `finish_reason=content_filter`  | Refusal. Exit 3.                                             |
| Truncated text, `finish_reason=length`      | Warned on stderr; raise `--max-tokens`.                      |

## 9. Payload hygiene and secrets

The single most common way to break an LLM shell script:

```bash
curl … -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$(cat diff.txt)\"}]}"
```

That is invalid JSON the first time the diff contains a quote, a backslash or a
`${…}` — which for a diff is immediately. jq owns the escaping instead:

```bash
jq -n --arg model "$MODEL" --rawfile prompt diff.txt '{model: $model, messages: [{role: "user", content: $prompt}]}'
```

`--rawfile` also keeps a megabyte-sized diff out of argv, where it would hit
`E2BIG`. The key gets the same care: `-H "Authorization: Bearer $KEY"` puts the
secret in argv, readable by any process on the machine, so the script writes
headers to a 0600 `curl --config` file and removes it on exit.

## 10. What leaves the building

A spec or a diff sent to OpenRouter leaves your network and reaches a gateway that
routes it onward to an upstream vendor. Decide once, per repository, whether that
is acceptable — then keep secrets, `.env` files, customer data and credentials out
of the prompt regardless. `git diff -- src/` beats `git diff` for that reason
alone, and it is the cheaper call too.

## 11. Beyond OpenRouter

The script still speaks two other shapes, for when a key does exist:
`-p openai` (or any OpenAI-compatible host via `--base-url`: Groq, Together, a
local Ollama on `http://localhost:11434/v1`, an internal gateway) and
`-p anthropic`, whose API differs in every load-bearing way — `x-api-key` instead
of `Authorization`, a required `anthropic-version` header, `system` as a
top-level field, mandatory `max_tokens`, and text under `.content[]` filtered on
`type == "text"` because extended thinking puts `thinking` blocks in the same
array. Inference: a slug containing `/` routes to OpenRouter, `claude-*` to
Anthropic, anything else to OpenAI. Their keys use the same
convention as §2 — `OPENAI_API_KEY` / `LLM_OPENAI_API_KEY`, `ANTHROPIC_API_KEY` /
`LLM_ANTHROPIC_API_KEY`, and `LLM_API_KEY` for a `custom` gateway — with the
`LLM_`-prefixed name winning when both are set.

## 12. Anti-patterns

| Anti-pattern                                        | Why it fails                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------- |
| Reviewing with the same model that wrote the code   | Shares the blind spot that produced the bug. The whole point is a different lineage. |
| Treating the output as a verdict                    | It produces candidates. Verification is not optional.               |
| Feeding the review back into the authoring agent    | Two models arguing; nobody decides.                                 |
| Sending the whole repository                        | Pay more, leak more, get a worse answer. §5.                        |
| Asking for a verdict instead of a refutation        | You get praise, and praise is worth nothing here.                   |
| `ANTHROPIC_BASE_URL` pointed at OpenRouter          | Reroutes Claude Code itself, not just your script.                  |
| `ANTHROPIC_API_KEY` exported "just for testing"     | Flips Claude Code to per-token API billing.                         |
| Keys in a project-scope `.claude/settings.json`     | Committed secret.                                                   |
| Interpolating a diff into a JSON string             | Invalid payload on the first quote. §9.                             |
| Hardcoding model slugs across scripts               | Slugs drift; use the alias file.                                    |
| Shrinking `--timeout` to "fail fast"                | You pay for the input and throw the answer away. §7.                |
| Retrying a 400 or 404                               | Deterministic refusals. Only 429/5xx/network are worth a retry.      |
| A dollar sign directly before a digit in a SKILL.md  | Slash-command argument substitution eats it: an amount like USD 2.50 written that way becomes the second word the user typed. |
| `grep`/`sed` over prose to drive control flow       | Ask for a delimited block, or request structure and parse with jq.  |

## 13. See also

- [static-validation-hooks](../static-validation-hooks/SKILL.md) — deterministic checks belong in a hook, not in an LLM call. Run those first; a model is for judgement, not for lint.
- [grievances](../grievances/SKILL.md) — where a confirmed finding goes when it is out of scope for the current spec.
- [spaghetti-compass](../spaghetti-compass/SKILL.md) — reverse impact analysis, to widen review context by callers rather than by volume.

---

## Implementation Status

**Fully implemented; live-verified except the completion call.**

`llm-ask.sh` was exercised against a stub provider on twenty paths: happy path,
prompt+stdin fidelity with quotes/backslashes/`${}` in the payload, HTTP 200
carrying an error object, 401, 429-then-success through the retry loop, empty
completion, truncation, the Anthropic response shape with a `thinking` block
correctly excluded, `--json`, `--out`, `--list-models` with a filter, connect
timeout, missing option value, temp-file cleanup, multi-`-f` block ordering, `-f`
with a pipe, `-f` with no instruction, the system prompt staying a separate
message, and the three `-f` rejections (missing, unreadable, directory). Auth
header shape is asserted per provider by the stub. Verified on bash 3.2.57 (macOS
system bash). Flag and environment coverage in §7 is audited mechanically against
the argument parser, and the documented defaults are diffed against the code.

Live against the real OpenRouter API: the catalogue cache was exercised end to
end — cold fetch (412 models, ~675 KB distilled to 78 KB in 0.45s), warm read
(0.03s), TTL honoured at 12h and refetched at 30h, `LLM_CACHE_TTL_H` override,
`--models-refresh` standalone, and two degradation paths under a dead network:
stale cache serves with a warning, absent cache fails `--top` with exit 2 while
leaving an ordinary call working minus the estimate. Ranking was checked across
all three metrics with vendor exclusion and a context floor, `@top` and `@top:N`
resolution, plus rejection of a bad selector and a bad metric. The cost estimate
was verified arithmetically against the catalogue rate after a unit bug was found
and fixed (prices are per million tokens, and were briefly being multiplied as
though per token). 140 of 412 models carry `artificial_analysis` scores.

The API surface documented in §6 was probed rather than assumed: `/api/v1/models`,
`?category=programming`, `/models/{id}/endpoints` and `/providers` answer without
a key; `/credits` and `/models/user` return 401; every `/api/frontend/*` route
returns 404.


`openrouter-key.fish` and `openrouter-key.sh` were run twice each in a sandboxed
`HOME`: file created at 0600, existing key left untouched on the second pass, no
duplicated line, `$HOME` written literally into the rc, and the key confirmed
exported by a shell that sources the result. **`openrouter-key.ps1` is untested** —
no Windows machine was available; it is a five-line script around
`[Environment]::SetEnvironmentVariable(…, 'User')`, but treat the first run as the
verification.

**Not verified:** the completion path itself. `chat/completions` has never been
called for real, because this machine holds no OpenRouter key. Auth, billing and
per-model parameter quirks are stub-verified only; your first real review is what
proves them.
