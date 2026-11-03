# conversation-focus on Claude Code

Reference implementation of the two rules in [../SKILL.md](../SKILL.md).
Verified against the Claude Code hooks reference on 2026-11-03:
<https://code.claude.com/docs/en/hooks> (sections "Stop", "Prompt-based
hooks", "Agent-based hooks").

## Event mapping

| Moment (SKILL.md) | Claude Code event | Script | Output |
|---|---|---|---|
| before the reply | `UserPromptSubmit` | `hooks/conversation-focus-prompt.sh` | `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"…"}}` |
| after the reply | `Stop` | `hooks/conversation-focus-stop.sh` | `{"decision":"block","reason":"…"}` or nothing |

Two payload facts the scripts rely on:

- `additionalContext` must be nested under `hookSpecificOutput`. At the top
  level it is silently ignored.
- The `Stop` input carries `last_assistant_message`, the final text of the
  turn. The docs say to prefer it over `transcript_path`, because the
  transcript is not guaranteed to hold the final message at Stop time. The
  transcript fallback in the script exists for older versions only.

## What the injected context says

`conversation-focus-prompt.sh` emits (desktop app variant):

```text
[conversation-focus] Apply to this reply. Do not mention these rules to the user.
- Split check, before any work: if this message opens a subject unrelated to the conversation's main subject (it builds on nothing said, found or decided so far), propose it as a separate session: call mcp__ccd_session__start_session with initiation "offer" and a short title naming the new subject, and do not start that work here unless the user says so. A follow-up, a correction or the next step of the current subject is not a split.
- Closing summary: end the reply with one final paragraph wrapped in single asterisks (*…*), 2-3 sentences in the user's language, stating the conversation's main subject and where it stands — the whole conversation, not only this turn. Nothing after it. Write it once per user message: when a Stop hook makes you continue after it was written (e.g. a session-title update), do not write it again.
- Summary references: end that italic paragraph, inside the asterisks, with markdown links to the objects this conversation tracks, separated by ' · ' — the Linear project a pilot session steers, the Linear issue the work implements, the pull request opened or reviewed (…). Once a reference has appeared in the conversation, repeat it in every later summary while it still applies. Use only URLs seen in this conversation or returned by a tool; never guess one, and omit the links when there are none.
```

The links sit inside the italic paragraph, so the Stop guard needs no change:
`*… · [PR #28](https://…)*` still starts and ends with a single `*`.

Outside the desktop app (`CLAUDE_CODE_ENTRYPOINT` is not `claude-desktop`),
`start_session` does not exist, and the split clause becomes "say so in one
line and suggest a 2-5 word title for a new session".

## Stop guard behaviour

| Input | Result |
|---|---|
| last paragraph `*Sujet : …*` or `_Sujet : …_` (may span lines) | pass |
| last paragraph plain text, or bold `**…**` | block once, reason asks for the summary paragraph only |
| `stop_hook_active: true` | pass, never loops |
| empty final text (tool-only turn) | pass |
| reply shorter than `CONVERSATION_FOCUS_MIN_CHARS` | pass |

Interaction with other Stop hooks: when `session-title-sync.sh` blocks in the
same Stop, both reasons reach the agent together. The continuation then runs
with `stop_hook_active: true`, so this guard passes through. Claude Code also
caps a run of stop-hook continuations at eight
(`CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`).

## Alternatives considered and rejected

| Option | Why not |
|---|---|
| Split check in a `Stop` hook | Too late. By Stop, the off-topic work has already been done in this session. |
| `type: "prompt"` Stop hook judging the split | The evaluator receives the hook JSON, `transcript_path` included, but only as a path. It is a single LLM call with no tools, so it sees `last_assistant_message` and never the conversation. It cannot tell "new subject" from "next step". |
| `type: "agent"` Stop hook reading the transcript | Experimental. It costs a subagent of up to 50 turns and about 60 s per turn. The docs do not document that it may read `transcript_path`; that is an inference. It also judges what the main agent already knows for free. |
| Producing the summary from the Stop hook | A Stop hook cannot edit a rendered reply. Every turn would show two messages. |

If a future Claude Code version lets a Stop hook amend the final message, the
guard can become a producer. Until then, keep "produce before, verify after".

## Installation (user level, recommended)

The rules are about how every conversation runs, not about one repo, so
install them once for all sessions, as `session-title` does. Copy both scripts
to `~/.agents/hooks/` and merge into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash ~/.agents/hooks/conversation-focus-prompt.sh", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash ~/.agents/hooks/conversation-focus-stop.sh", "timeout": 10 } ] }
    ]
  }
}
```

Do not also wire them at project level: the rules would be injected twice.
Re-copy the scripts after changing them in this repo; the installed copies do
not follow edits.

## Installation (project level)

Only for a repo whose users do not have the user-level install. A project-level
wiring reaches only sessions opened on that repo, and only once the scripts and
the settings are committed: a worktree session starts from the last commit, so
uncommitted hooks never fire there. Merge into the repo's `.claude/settings.json`:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "bash hooks/conversation-focus-prompt.sh", "timeout": 5 } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash hooks/conversation-focus-stop.sh", "timeout": 10 } ] }
    ]
  }
}
```

The commands resolve against the project root, which is where Claude Code
runs project hooks.
