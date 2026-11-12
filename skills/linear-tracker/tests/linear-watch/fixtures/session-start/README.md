# Recorded SessionStart payloads

Captured on 2026-11-12 with Claude Code CLI 2.x, headless, through a
throwaway settings file whose SessionStart hook (`startup|resume`) copied its
stdin to a file:

```bash
claude -p --model haiku --settings settings.json "Reply with the single word ok."
claude -p --model haiku --settings settings.json --resume <session_id> "Reply with the single word ok again."
```

| File | `source` | Notes |
|---|---|---|
| `startup.json` | `startup` | first run of the session |
| `resume.json` | `resume` | same session resumed: extra keys `seconds_since_last_response`, `context_tokens`, `prompt_cache_likely_expired`, `estimated_cache_write_usd` |

Only `transcript_path`, `cwd` and `scratchpad_dir` were edited (the home
folder and the scratchpad path were replaced). Every other key is verbatim.

**Measured:** `--resume` keeps the `session_id` (`3c2598fd-…` in both). The
SessionStart hook therefore finds a resumed session's subscriptions by the
payload id alone. Not measured: whether the Claude desktop app ever resumes a
session under a new CLI id (its session files carry `priorCliSessionIds`, so
it may); `lw` does not carry subscriptions across ids.
