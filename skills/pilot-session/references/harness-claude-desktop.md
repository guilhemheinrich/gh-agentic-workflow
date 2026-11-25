# Harness reference — Claude Desktop (Code tab)

How this harness launches, follows and bounds sub-sessions, and what a pilot
does about each limit. Another harness gets its own file next to this one,
answering the same questions: how a sub-session is launched, how its report
comes back, what wakes an idle pilot, and what the harness refuses to do on its
own.

## Launching sub-sessions

- A sub-session is a **subagent** launched with the Agent tool. The brief is its
  prompt; it starts with none of the pilot's context (`subagent_type`
  `general-purpose`, or a fresh specialised agent). It is not a side session:
  no card, no approval, nothing in the sidebar.
- **Set the model on the launch** (`model`: `sonnet` for coding and debugging,
  `haiku` for a read-only verification that only collects facts, `opus` or
  `fable` for planning, arbitration and security). A model stronger than the
  pilot's is honoured: there is no two-step escalation.
- **Isolate code work**: `isolation: "worktree"`. Independent sub-sessions go in
  one message and run in parallel; with `run_in_background` the pilot is
  notified when each ends and keeps working meanwhile.
- Follow-ups go to the sub-session that has the context (`SendMessage` to its
  agent id), not to a new one.
- No turn type blocks a launch: the "only asked-for starts run from an event"
  limit of side sessions does not apply, nor the click-a-card limit for another
  repository (the sub-session's brief names the repository path).

## Hearing back

- A sub-session's final report comes back as the Agent call's result, or as a
  notification when it ran in the background. A report is the sub-session's
  word, not proof: check the change before relaying.
- A sub-session cannot be woken after it ends, and the app's native PR monitor
  (`ccd_pr` Auto-fix) wakes the session that owns the PR, not a subagent. The
  **pilot** therefore follows each PR with `pr-watch`, and sends a fix back with
  `SendMessage` or launches a new sub-session.
- The app re-invokes an idle pilot when one of its background commands exits.
  A watcher that blocks until news arrives (for example `prw wait` from the
  `pr-watch` skill), run in the background, is therefore a wake source.

## Worktrees

A sub-session in its own worktree commits on its own branch. Nothing it did is
in the pilot's checkout until merged; never merge a sub-session's branch into
the pilot's checkout unless the human asks. Remove the worktree once its branch
is merged.

## Never poll

No sleep loops, no scheduled re-checks of CI. Background waits and sub-session
results re-invoke the pilot when something changes.
