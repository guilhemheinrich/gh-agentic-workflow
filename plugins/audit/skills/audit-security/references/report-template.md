# Report template and severity rubric

> **Language (mandatory):** write the report, headings and severity labels in the
> language of the person who asked. This template is in English; translate its
> prose, keep code, paths, identifiers and rule ids verbatim.

The report is written to `$OUT/SECURITY-AUDIT.md`, next to the tool outputs
and outside the checkout, then handed to the requester where they ask. It must stand alone: a reader who never saw the audit session can
re-check every line.

Three rules for the text itself:

- No secret value, ever. `file:line` and rule id only.
- Every finding has a re-verify step whose result changes when the fix
  lands: a scanner command, or a named test. "Review the code again" is not
  one, and neither is a grep that stops matching: renaming a variable makes
  the grep silent and leaves the flaw.
- State what was **not** done. An unscanned area reported as clean is the
  worst outcome of an audit.

## Severity rubric

Severity is read from a grid, then adjusted by named bumps. Write the cell
in the finding (`E2 x I3 = High`) so the reader can disagree with a specific
judgement instead of with a colour.

**Exploitability**: how hard is it for an attacker to trigger?

| Level | Definition | Example |
|---|---|---|
| E3 | Remote, no account needed, no victim action | `GET /calc?expr=...` reaching `eval` on a public route |
| E2 | Needs any valid account, or needs a victim to click or visit | IDOR for logged-in users; reflected XSS through a link; a double-spend race (a few dozen parallel requests are enough) |
| E1 | Needs admin rights, local or network-internal access, or an unlikely state | SQL injection in an admin-only export; a flaw reachable only while a migration is running |

**Impact**: what does the attacker get?

| Level | Definition | Example |
|---|---|---|
| I3 | Code execution, authentication bypass, data of other tenants or of all users, credentials | Shell on the API server; any user reads any invoice |
| I2 | One victim's account or data, limited integrity loss, stored content injection | Session theft through XSS; changing another user's avatar |
| I1 | Information of little direct use, degraded service, missing hardening | Framework version disclosed; missing `frame-ancestors` on a page with no sensitive action |

| | I3 | I2 | I1 |
|---|---|---|---|
| **E3** | Critical | High | Medium |
| **E2** | High | Medium | Low |
| **E1** | Medium | Low | Info |

**Bumps**, applied after the grid, each one written in the finding:

| Condition | Effect |
|---|---|
| Dependency CVE in CISA KEV, reachable or reachability unknown | Critical |
| Malicious package installed | Critical, and open an incident |
| Dependency CVE reachable from an unauthenticated endpoint | Up one level |
| Credential found and still valid (confirmed by its owner, or by `scan-secrets.sh --verify` run with the owner's authorization) | Critical |
| Credential found, already rotated | Low; keep the entry as a record |
| Dependency CVE with the vulnerable function proven not called | Down one level, justification mandatory |
| Flaw sits behind a compensating control that was read and verified (not assumed) | Down one level, cite the control's `file:line` |

Dependencies do not use the grid. They start from the script's priority (P0
Critical, P1 High, P2 Medium, P3 Low), then take the bumps above. EPSS is
already inside P1: it is not a bump. Each bump applies once.

| Case | Start | Bump | Result |
|---|---|---|---|
| CVSS 9.1, not in KEV, called on a public route (F-07 below) | P1 High | reachable unauthenticated: up | Critical |
| EPSS 0.202, reachability not analysed | P1 High | none | High |
| In KEV, reachability unknown | P0 Critical | none needed | Critical |
| In KEV, function proven not called | P0 Critical | proven unreachable: down | High, proof in the finding |
| No CVSS and no label, never shipped (`devDependencies`) | P2 Medium | not shipped: down | Low |

Worked example of a disagreement the grid makes visible: "`localStorage`
token, `src/widget.js:16`: E2 (needs an XSS first) x I2 (one user's session)
= Medium. Bumped to High because finding F-03 is a DOM XSS on the same
origin, which makes the precondition real."

## Skeleton

```markdown
# Security audit: <application>

| | |
|---|---|
| Repository | <url or path> |
| Commit | <git rev-parse HEAD> |
| Date | <YYYY-MM-DD> |
| Requested by | <name or role> |
| Auditor | <agent or person> |
| Skill | audit-security |

## 1. Summary

<Three to five sentences a manager can act on: the worst thing found, how
many findings per severity, what to do this week.>

| Severity | Count |
|---|---|
| Critical | n |
| High | n |
| Medium | n |
| Low | n |
| Info | n |

## 2. Scope and method

- In scope: <directories, services>
- Out of scope: <and which sibling audit owns it: audit-database, audit-infra, audit-frontend>
- Application model: <users, roles, tenants, trust boundaries, auth provider>

| Step | Tool and version | Run date | Result |
|---|---|---|---|
| Dependencies | osv-scanner v2.7.1 | <date> | <n advisories on m packages> |
| Exploitation data | KEV catalog <version>, EPSS <date> | <date> | <n at P0, n at P1> |
| Secrets, worktree | gitleaks v8.30.1 | <date> | <n> |
| Secrets, history | gitleaks v8.30.1, all refs, <n commits> | <date> | <n> |
| SAST | semgrep 1.186.0, <rulesets> | <date> | <n leads, n confirmed> |
| Manual review | sast-expert-checklist.md, sections <list> | <date> | <n findings> |

## 3. Not covered

<Honest list. Every `INCOMPLETE` line a script printed goes here, and every
manifest absent from `deps-coverage.json`. Examples: "history scan
incomplete: shallow clone"; "`services/billing/pnpm-lock.yaml` not scanned
(API fallback)"; "mobile app in /ios not reviewed"; "reachability of the 4
P2 lodash advisories not analysed"; "semgrep: 3 parse errors in
src/legacy/"; "checklist section 18: 40 of 310 leads read".>

## 4. Findings

<One block per finding, ordered by severity then by id.>

## 5. Dependency triage

<The table from deps-triage.md, with a "Decision" column: upgrade to x.y.z,
replace, not affected (why), accepted (by whom, until when).>

## 6. Observations

<Things that failed the "is it a finding?" test but are worth a line.>

## 7. Positive notes

<Controls that were checked and found correct. They tell the next auditor
what not to redo, and tell the team what not to break. Cite file:line.>
```

## Finding block

```markdown
### F-01: <what is wrong, in plain words>

| | |
|---|---|
| Severity | <Critical/High/Medium/Low/Info> (<Ex x Iy>, or <Pn> for a dependency; bumps: <none or which>) |
| Class | <CWE-nnn name> / <OWASP A0x:2021> / <OWASP A0x:2025> / <ASVS 5.0 chapter> |
| Location | `<file>:<line>` |
| Found by | <tool and rule id, or "manual review, checklist section n"> |

**Evidence.** <Data flow: the attacker-controlled input, where it enters,
the sink it reaches. Missing control: the route or asset, who can reach it,
the control expected and where you looked for it. Quote at most the few
lines needed, never a secret.>

**Impact.** <One or two sentences: who loses what.>

**Fix.** <The change, concrete enough to implement. Prefer the smallest
correct change, then mention the structural one if any.>

**Re-verify.** <A scanner command whose output changes, or a test named
precisely enough to be written: request, caller, expected status. Say if
the test does not exist yet.>
```

## Worked example

Written against the fixture, `scripts/fixtures/vulnerable-app`.

```markdown
### F-01: Any caller can read any invoice by changing the id

| | |
|---|---|
| Severity | Critical (E3 x I3, no bump) |
| Class | CWE-639 Authorization Bypass Through User-Controlled Key / A01:2021 / A01:2025 / ASVS V8 Authorization |
| Location | `src/app.js:43` |
| Found by | manual review, checklist sections 1 and 2. No scanner reported it. |

**Evidence.** `GET /invoices/:id` passes `req.params.id` to
`db.invoices.findById` (line 44) and returns the result (line 45). The
route has no authentication middleware, and nothing between the route
declaration and the response compares the invoice's owner or tenant with
the caller. E3 because no account is needed; it would be E2 (High) if the
route required a login and only the ownership check were missing.

**Impact.** Anyone can read every customer's invoices by iterating ids:
names, addresses, amounts.

**Fix.** Require authentication on the route, and scope the query to the
caller: look the invoice up by `{ id, tenantId: req.user.tenantId }` and
return 404 when nothing matches. Structurally: make the tenant filter part
of the data-access layer so a handler cannot forget it.

**Re-verify.** No test exists today, so the fix ships with one, three
cases on `GET /invoices/:id`: anonymous gets 401; a user of tenant A asking
for an invoice of tenant B gets 404; the owner gets 200. The first two fail
on the current code. Reading `src/app.js:43-46` again is a complement, not
the proof.
```

And a dependency finding:

```markdown
### F-07: lodash 4.17.4, prototype pollution reachable from a public route

| | |
|---|---|
| Severity | Critical (P1 from triage: CVSS 9.1 = High; bump: reachable from an unauthenticated route, up one level) |
| Class | CWE-1321 / A06:2021 / A03:2025 / ASVS V15 |
| Location | `package-lock.json` (lodash 4.17.4), called at `src/app.js:50` |
| Found by | osv-scanner, GHSA-jf85-cpcp-j695 (CVE-2019-10744); reachability by manual review |

**Evidence.** CVE-2019-10744 affects `defaultsDeep` before 4.17.12.
`src/app.js:50` calls `_.defaultsDeep({}, req.body)` on `POST /settings`,
with the raw JSON body. Not in CISA KEV; EPSS 0.050 (92nd percentile) on
2026-11-23.

**Impact.** A crafted body adds attacker-chosen properties to every object
of the process (primitive confirmed: `({}).isAdmin` becomes true). What it
yields depends on code that reads a property it never set; none was traced
in this fixture, so the consequence beyond the primitive is not claimed.

**Fix.** Upgrade lodash to the latest 4.x (4.17.21 closes this one; the
triage table lists advisories fixed only in later releases). Validate the
body against a schema before merging.

**Re-verify.** `<skill>/scripts/scan-deps.sh --out "$OUT" .` currently lists
`GHSA-jf85-cpcp-j695`; after the upgrade it does not.
```

## Before sending

| Check | How |
|---|---|
| No secret in the report | copy `SECURITY-AUDIT.md` alone into an empty directory, then `<skill>/scripts/scan-secrets.sh --no-history --out "$(mktemp -d)" <that directory>` exits 0 |
| Every finding has `file:line`, CWE, severity cell or priority, re-verify step | read each block |
| Every `INCOMPLETE` line and every unscanned manifest is in "Not covered" | compare with the script logs and `deps-coverage.json` |
| Counts in the summary match the blocks | count them |
| "Not covered" is filled in | an empty section means it was forgotten, not that everything was covered |
| Each tool row has a version and a date | scores and rules change daily |
| Findings that belong to a sibling audit are named, not silently dropped | audit-database, audit-infra, audit-frontend |
