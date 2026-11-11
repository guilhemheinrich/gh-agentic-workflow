# Child brief — <ITEM-REF>: <short title>

<!-- Copy, fill every <…>, delete every line that does not apply to this body
of work. The child has none of the pilot's conversation: never write "as
discussed", restate it. Optional sections are marked; keep them only when the
tooling they name is actually in place. -->

<!-- Before sending: start this session on the model that fits the task, not
on the pilot's model (SKILL.md §5) — e.g. in Claude, Sonnet for coding and
debugging. -->

You are a child session of a pilot session. You own one piece of work, end to
end, up to a change that passes its gates. You do not integrate it yourself
<unless the charter says otherwise>.

## The work

- **Item**: <REF> — <link, if any>
- **Linear** (keep only if the tracker is Linear): project `<PROJECT NAME>`,
  issue `<TT-NNN>` (or "none yet"). Write the project into the spec's
  `linear.json` before the spec exists
  (`.claude/hooks/linear-record.sh specs/<NNN-slug> project "<PROJECT NAME>"`),
  and the issue with `linked <ID> <URL>` if it already exists.
- **Goal**: <two sentences: what changes, for whom>
- **Context you need**: <the facts the pilot already established: files, prior
  changes, decisions taken, links>
- **Done when**: <the observable fact: change open on <target branch>, CI
  green, review comments addressed / proof attached>
- **Scope: OUT**: <what you must not do, even if it looks related>

## Repository constraints

- Repository: <path or URL>; target branch: <…>
- Follow the repository's agent instructions (<AGENTS.md / CLAUDE.md / …>) and
  its hooks.
- <Execution rules, e.g. "everything runs in Docker".>
- <Language rules for committed files.>
- <Shared environments to leave running.>

## Conventions of this body of work

- One item = one branch (`<naming rule>`) = one change to `<target>`.
- <Item reference in the change description and in each commit, e.g.
  `Refs: <REF>`.>
- <Link the change on the item and move its status, if the tracker is yours
  to update.>
- Out-of-scope findings: record them (<ledger or tracker>), do not fix them
  here.

## Optional — review before integration

<Keep only if cross-model review tooling is available and the change is worth
it.> Before asking for integration, have the diff attacked by <2–3 models from
other vendors> through <tool>. Fix blocking findings; list the others in the
change description.

## Optional — Git-host watcher

<Keep only if a watcher is installed.> After pushing, make sure the change is
watched (<command>) and keep the wait running in the background. Follow CI and
review comments; fix failures and address comments until green.

## Optional — verification child (read-only)

- Read-only on shared infrastructure; anything beyond reading goes to a
  report for whoever operates it.
- Never print a secret or a token.
- Report facts first — versions, verbatim log lines, status codes — then the
  interpretation.

## Reporting back

End each turn with: state (working / change open / green / blocked), link,
CI state, and the one question you need answered, if any. Stop and ask the
pilot — do not guess — when: <the scope is unclear | a business rule is
ambiguous | access is denied | an action would touch production>.
