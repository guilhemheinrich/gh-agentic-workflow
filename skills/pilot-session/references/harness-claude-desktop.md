# Harness reference — Claude Desktop (Code tab)

How this harness starts, wakes and bounds side sessions, and what a pilot does
about each limit. Another harness gets its own file next to this one, answering
the same questions: how a child is started, how its report comes back, what
wakes an idle pilot, and what the harness refuses to do on its own.

## Starting children

- A child is a side session started from the pilot (`start_session`). The
  brief is its first prompt; `context: "fresh"` for a self-contained brief.
- **Set the child's model on the start call** (`start_session`'s `model`
  parameter): coding and debugging children start on `sonnet`; a read-only
  verification child may take `haiku` when it only collects facts. Without the
  parameter the child inherits the pilot's model. A `model` **stronger** than
  the pilot's own is ignored: see "Escalating a child's model".
- Follow-ups go to the child that has the context (`SendMessage` to its
  session id), not to a new session.
- **Only asked-for starts run from an event.** On a turn started by another
  session's message or an automated event, the app refuses to start a session
  and turns it into a proposal card — except on a side-session event that
  directly follows a user turn, for steps the user asked to have in their own
  session, and in this project only. Hence the skill (§2) starts the planned children on the user turn that
  invokes it: the charter's scope is the ask.
- A child whose working directory is another repository falls outside "this
  project only": on an event-driven turn it becomes a card the human clicks.
  Start those on a user turn when possible, or batch their cards.

## Escalating a child's model

Verified: `start_session` ignores a `model` stronger than the pilot's, so the
child starts on the pilot's model. Switch it after the start:

1. **Start read-only.** The brief's first line is "Read-only until told to
   proceed: do not analyse or answer yet, reply 'ready' only."
2. **Switch.** `set_session_model` on the child's session id (optionally
   `set_session_effort`). Raising to a more expensive model makes the app ask
   the human for one approval; say in one line why ("planning needs Opus").
   It is refused on the pilot's own session and applies from the child's next
   turn.
3. **Go.** Once switched, send the real instruction with `SendMessage`.

## Hearing back

- **A child's report reaches the pilot only when no session it started is
  still working.** With three children in parallel, a green change from the
  first would wait for the other two to go idle. Do not rely on reports to
  learn that a change is green: subscribe the pilot itself to each child's
  change through the Git-host watcher, when there is one. On GitHub the app's
  native monitor only wakes a session for CI failures, conflicts and review
  comments, and only with Auto-fix on for that PR (`ccd_pr` `set_monitor`):
  each child enables it, and `pr-watch` covers the rest for the pilot.
- **Event chains run out.** After many side-session events in a row with no
  user message, further reports wait for the next user turn. When the pilot
  notices a long chain, it posts a short status and its next planned step so
  the human can relaunch with one word.
- The app re-invokes an idle session when one of its background commands
  exits. A watcher that blocks until news arrives (for example `prw wait` from
  the `pr-watch` skill), run in the background, is therefore a wake source.
- A report is the child's word, not proof: check the change before relaying.

## Worktrees

A child in its own worktree commits on its own branch. Nothing it did is in
the pilot's checkout until merged; never merge children's branches into the
pilot's checkout unless the human asks.

## Never poll

No sleep loops, no scheduled re-checks of CI. Background waits and side-session
reports re-invoke the pilot when something changes.
