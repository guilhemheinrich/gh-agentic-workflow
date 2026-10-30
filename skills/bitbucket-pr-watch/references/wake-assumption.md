# Wake assumption — measurements

The whole design rests on one harness behaviour: **an idle Claude session is
re-invoked when one of its background commands exits.** These are the
measurements, in the Claude desktop app (Code tab), macOS.

| # | Check | Date | Result |
|---|---|---|---|
| 1 | `sleep 90; echo …` with `run_in_background`, session idle | 2026-10-30 | **Pass.** Command ended 17:13:50Z; the session took a turn at 17:13:55Z with no human input. |
| 2 | `sleep 3700; echo …` — does a background command survive past one hour? | 2026-10-30 | Pending at the time of writing; see the line below once measured. |
| 3 | Does `session_id` survive an app restart and a session reopen? | — | Not measured: needs the human to quit and reopen the app. If it changes, the SessionStart hook must re-key subscriptions by repo and branch of the cwd. |

How to re-measure check 1 in any harness: arm `sleep 90; echo WAKE` the way
the adapter arms `bbw wait`, end the turn, and watch for a turn starting about
90 s later with nobody typing.
