# Tasks: 017-session-metadata

- [x] T001 Write `skills/session-meta/scripts/session-meta.py`: SQLite triple store with get/set/append/incr/unset/find/sessions (FR-1..FR-6)
- [x] T002 Write `skills/session-meta/scripts/test_session_meta.py` with open keys, harness partition, 10 concurrent appends and find, run in Docker
- [x] T003 Make `hooks/conversation-focus-prompt.sh` count `turns`, inject the scope/subject clause with the filled-in commands, claim precedence, and fail open without the CLI (FR-7..FR-9)
- [x] T004 Document the skill in `skills/session-meta/SKILL.md`, add the anchored split to `skills/conversation-focus/SKILL.md`, and register the skill in `asset-registry.yml`
- [x] T006 Make `skills/session-title/scripts/session-title.sh` read the `pilot`/`subject` pins from the store and write `pilot` there; show the pinned subject in `hooks/session-title-sync.sh` (FR-10)
- [x] T005 Install on the machine and check live: 12 of 26 sessions classified `focused` within their first 3 messages; one split offered and recorded in `split_events`
- [x] T007 Measure and document the CLI path for opening a child session in another project folder (`claude --bg`), which the desktop app does not allow
