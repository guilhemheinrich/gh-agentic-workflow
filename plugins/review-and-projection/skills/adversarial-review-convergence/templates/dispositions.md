# Dispositions — {SPEC ID} {ARTIFACT}, round {ROUND}

Every finding the panel returned gets exactly one row, and exactly one verdict.
A finding with no row is a finding silently accepted or silently ignored, and
nobody can tell which afterwards.

| # | Lane(s) | Sev | Verdict | Evidence | Conv |
| - | ------- | --- | ------- | -------- | ---- |
| 1 | sol, grok | CRITICAL | accepted | patched in `plan.md:88-120` | Y |
| 2 | sol | CRITICAL | refuted | `internal/store/doc.go:214` already takes the lock | N |
| 3 | grok | MAJOR | routed | GRV-0042 | N |
| 4 | sol, grok | MAJOR | refuted | `plan.md:230` described its own code wrongly; actual behaviour at `internal/api/upload.go:61` | Y |
| 5 | grok | MINOR | routed | `specs/201-document-gc/spec.md` | N |

## The three verdicts, and what each one costs

| Verdict   | Means | Required evidence |
| --------- | ----- | ----------------- |
| `accepted` | The finding is true and the artifact changed. | Where the change landed. |
| `refuted`  | The finding is false. | **`file:line` in the real repository.** Disagreement is not evidence. A second model agreeing with the first is not evidence either — both can inherit a false premise from the artifact. |
| `routed`   | The finding is true, and out of scope. | A grievance id (`GRV-NNNN`) or a spec path. Never a promise. |

There is no fourth verdict. "Noted", "partially accepted" and "will consider"
are how a review fails to terminate.

## Convergence column

`Y` when both lanes named the same defect independently. It raises the bar for
refutation — a convergent finding refuted on one line deserves a second look —
and it never lowers it. Row 4 above is the case that matters: two lanes agreed,
and both were wrong, because the artifact's own prose misdescribed the code they
could not see.

## Conclusion

<!--
  One line. The orchestrator's own words, not a restatement of the table.
  It says what the round changed and what happens next.
-->

## Conclusion

{Example: "Three criticals collapsed into one root cause — the pre-existing row
with no anchor — which removed five patches and four migrations; round plan-4
is the last, and nothing below MAJOR will be answered in it."}
