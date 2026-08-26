You are reviewing planning artefacts produced by another AI (Claude). Your job is
to find what it got wrong, not to summarise or praise it.

The work is a spec-kit feature: change a Python CLI so grievance identifiers stop
being a sequential counter (GRV-0001) and become a slug derived from the
grievance's own short description (GRV-worker-hosted-api-scale). The motivation is
that two developers branching from a common ancestor always compute the same next
number.

You are given, in FILE blocks:
  - spec.md, plan.md, tasks.md, research.md, data-model.md, contracts/cli-commands.md
    — the artefacts under review
  - grievances.py — the ACTUAL 1061-line script the plan proposes to change,
    at the exact commit the plan's line numbers refer to
  - SKILL.md — the skill's current user-facing documentation

Because you have the real source, you can and MUST verify the plan's factual
claims about it rather than taking them on trust. Claims worth checking:
  - the cited line numbers point at what the plan says they do
  - the list of touchpoints is COMPLETE — find any place in grievances.py that
    depends on identifiers being numeric, or on their length, or on their sort
    order, that the plan does not mention
  - the widened regex claim: that the legacy and slug forms are disjoint, that
    BLOCK_RE keeps its group numbering and backreference, and that no other
    regex or string operation in the file breaks
  - that deleting Ledger.next_id leaves no caller
  - that audit_repo and cmd_migrate genuinely need no change

Report only defects you can tie to a specific location: cite file:line from the
FILE blocks, state what breaks, and name the input or condition that triggers it.
Prefer one demonstrated defect over five plausible ones.

Look for, in priority order:
  1. MISSED TOUCHPOINTS — code in grievances.py that this plan will break and does
     not mention. This is the highest-value finding you can produce.
  2. Requirements that are untestable as written.
  3. Contradictions between spec, plan, data-model, contracts and tasks — including
     a task whose ordering makes its own test impossible to fail first.
  4. Missing failure cases in the design.
  5. Assumptions held silently.

Constraints you must respect, and must NOT report as defects:
  - Python 3.12, standard library only. Suggesting a dependency is not a finding.
  - Every command runs in a Docker container. Suggesting a host interpreter is not
    a finding.
  - Committed artefacts are English-only.
  - The recurrence-counter (occurrences) merge defect is DELIBERATELY out of scope
    and documented as such. Do not report it as an omission.
  - The residual textual git conflict is DELIBERATELY accepted. Do not report it.
  - Renaming existing legacy identifiers is DELIBERATELY refused. Do not propose it.

Label anything you cannot ground in the provided text as SPECULATIVE. Do not
review files outside the blocks provided. If you find nothing, say "no defect
found" rather than inventing something.

Structure your answer as a numbered list. For each finding give:
  SEVERITY (blocker | major | minor) · LOCATION (file:line) · WHAT BREAKS ·
  TRIGGER · SUGGESTED FIX (one or two sentences).
