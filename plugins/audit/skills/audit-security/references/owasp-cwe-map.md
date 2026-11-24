# Finding class to CWE, OWASP Top 10 and ASVS

Use this table to label a finding. One primary CWE per finding; add a second
only when it changes the fix.

How it was checked (2026-11-24):

- **OWASP 2021 and 2025 columns**: each CWE was looked up in the "List of
  Mapped CWEs" of the category pages on `owasp.org/Top10/2021/` and
  `owasp.org/Top10/2025/`. A category in parentheses, like `(A03)`, means the
  CWE is **not** in OWASP's mapped list and the category is this skill's
  judgement by nearest class. Say "closest category" in the report.
- **CWE names**: read from `cwe.mitre.org`, CWE version 5.0.
- **ASVS column**: chapter of ASVS 5.0.0 only (chapter names read from the
  `v5.0.0` tag of `github.com/OWASP/ASVS`). The chapter is assigned by topic
  and requirement numbers are not given, because they were not checked one
  by one: open the chapter and find the requirement before citing a number.

OWASP Top 10 2025 reshuffled the list. The three changes that matter here:
SSRF lost its own category and joined A01; "Vulnerable and Outdated
Components" became A03 "Software Supply Chain Failures"; error handling got
its own A10 "Mishandling of Exceptional Conditions". Semgrep already tags
findings with both years (seen on the fixture: `A03:2021 - Injection` and
`A05:2025 - Injection` on the same hit).

| 2021 | 2025 |
|---|---|
| A01 Broken Access Control | A01 Broken Access Control |
| A02 Cryptographic Failures | A04 Cryptographic Failures |
| A03 Injection | A05 Injection |
| A04 Insecure Design | A06 Insecure Design |
| A05 Security Misconfiguration | A02 Security Misconfiguration |
| A06 Vulnerable and Outdated Components | A03 Software Supply Chain Failures |
| A07 Identification and Authentication Failures | A07 Authentication Failures |
| A08 Software and Data Integrity Failures | A08 Software or Data Integrity Failures |
| A09 Security Logging and Monitoring Failures | A09 Security Logging and Alerting Failures |
| A10 Server-Side Request Forgery | merged into A01 |
| (none) | A10 Mishandling of Exceptional Conditions |

## Access control

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| IDOR: object fetched by id without checking it belongs to the caller | CWE-639 Authorization Bypass Through User-Controlled Key | A01 | A01 | V8 Authorization |
| Route with no authorization check at all | CWE-862 Missing Authorization | A01 | A01 | V8 |
| Check present but wrong (role compared loosely, tenant not compared) | CWE-863 Incorrect Authorization | A01 | A01 | V8 |
| Sensitive action reachable without logging in | CWE-306 Missing Authentication for Critical Function | A07 | A07 | V6 Authentication |
| Path traversal | CWE-22 Improper Limitation of a Pathname to a Restricted Directory | A01 | A01 | V5 File Handling |
| CSRF | CWE-352 Cross-Site Request Forgery | A01 | A01 | V3 Web Frontend Security |
| Open redirect | CWE-601 URL Redirection to Untrusted Site | A01 | A01 | V2 Validation and Business Logic |
| SSRF | CWE-918 Server-Side Request Forgery | A10 | A01 | V1 Encoding and Sanitization |
| Mass assignment (request body bound straight to a model) | CWE-915 Improperly Controlled Modification of Dynamically-Determined Object Attributes | A08 | A08 | V15 Secure Coding and Architecture |
| Prototype pollution | CWE-1321 Improperly Controlled Modification of Object Prototype Attributes | (A08) | (A08) | V15 |
| Check-then-act race: double spend, coupon reuse | CWE-362 Concurrent Execution using Shared Resource with Improper Synchronization (CWE-367 for a pure time-of-check/time-of-use) | (A04) | A06 | V2 |
| Workflow step skipped or replayed | CWE-841 Improper Enforcement of Behavioral Workflow | A04 | A06 | V2 |
| `X-Forwarded-For` or `Host` trusted from the client | CWE-348 Use of Less Trusted Source | (A05) | (A02) | V13 |

CWE-1321 is a child of CWE-915, hence the A08 by proximity.

## Authentication, tokens, sessions

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| JWT signature not verified, `alg: none` accepted, `decode` used instead of `verify` | CWE-347 Improper Verification of Cryptographic Signature | A02 | A04 | V9 Self-contained Tokens |
| JWT verified but `aud` / `iss` / `exp` not checked | CWE-287 Improper Authentication | A07 | A07 | V9 |
| Signing secret or API key in source code or in the front-end bundle | CWE-798 Use of Hard-coded Credentials | A07 | A07 | V13 Configuration |
| Hard-coded encryption or signing key specifically | CWE-321 Use of Hard-coded Cryptographic Key | A02 | A04 | V11 Cryptography |
| Session cookie without `Secure` | CWE-614 Sensitive Cookie in HTTPS Session Without 'Secure' Attribute | A05 | A02 | V3 |
| Session cookie without `HttpOnly` | CWE-1004 Sensitive Cookie Without 'HttpOnly' Flag | A05 | A02 | V3 |
| Session cookie with `SameSite` missing or set to `None` without need | CWE-1275 Sensitive Cookie with Improper SameSite Attribute | A01 | A01 | V3 |
| Session id not regenerated at login | CWE-384 Session Fixation | A07 | A07 | V7 Session Management |
| Session or token never expires, logout does not invalidate | CWE-613 Insufficient Session Expiration | A07 | A07 | V7 |
| No rate limit or lockout on login, reset, OTP | CWE-307 Improper Restriction of Excessive Authentication Attempts | A07 | A07 | V6 |
| Weak password reset (guessable token, no expiry, user enumeration) | CWE-640 Weak Password Recovery Mechanism for Forgotten Password | A07 | A07 | V6 |
| OAuth callback bound by none of `state`, PKCE or `nonce`; IdP login linked to an existing account by email (verified or not) instead of `iss` + `sub` | CWE-352; CWE-287 | A01; A07 | A01; A07 | V10 OAuth and OIDC |
| Password hashed with MD5, SHA-1, SHA-256, or a low work factor | CWE-916 Use of Password Hash With Insufficient Computational Effort | A02 | A04 | V11 |
| Token stored in `localStorage` / `sessionStorage` | CWE-922 Insecure Storage of Sensitive Information | A01 | A01 | V14 Data Protection |

CWE-613 is marked **DEPRECATED** in CWE 5.0 ("insufficiently clear", MITRE
points to CWE-1462 and its descendants) but both OWASP lists still cite it.
Keep 613 for now and mention the deprecation if the reader is CWE-literate.

## Injection and unsafe input handling

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| SQL injection | CWE-89 | A03 | A05 | V1 |
| NoSQL injection (operator injection in MongoDB and similar) | CWE-943 Improper Neutralization of Special Elements in Data Query Logic | (A03) | (A05) | V1 |
| OS command injection | CWE-78 | A03 | A05 | V1 |
| Code injection, `eval`, `new Function`, `vm` | CWE-94, CWE-95 | A03 | A05 | V1 |
| Server-side template injection | CWE-1336 Improper Neutralization of Special Elements Used in a Template Engine | (A03) | (A05) | V1 |
| XSS: reflected, stored, DOM | CWE-79 | A03 | A05 | V1, V3 |
| HTTP header / response splitting | CWE-113 | A03 | A05 | V1 |
| XML external entity | CWE-611 | A05 | A02 | V1 |
| Unsafe deserialization (`pickle`, `yaml.load`, Java native, `node-serialize`) | CWE-502 Deserialization of Untrusted Data | A08 | A08 | V1 |
| File upload without type, size or location control | CWE-434 Unrestricted Upload of File with Dangerous Type | A04 | A06 | V5 |
| Regular expression denial of service | CWE-1333 Inefficient Regular Expression Complexity | (A04) | (A06) | V1 |
| No limit on body size, page size, or expensive operation | CWE-770 Allocation of Resources Without Limits or Throttling | (A04) | (A06) | V2 |

## Cryptography

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| `Math.random()`, `random.random()`, `rand()` for tokens, ids, OTPs | CWE-338 Use of Cryptographically Weak PRNG | A02 | A04 | V11 |
| MD5 / SHA-1 for integrity or signatures | CWE-328 Use of Weak Hash | A02 | A04 | V11 |
| DES, RC4, ECB mode, static IV | CWE-327 Use of a Broken or Risky Cryptographic Algorithm | A02 | A04 | V11 |
| Sensitive data sent over plain HTTP by the app | CWE-319 Cleartext Transmission of Sensitive Information | A02 | A04 | V12 Secure Communication |
| Sensitive data stored unencrypted | CWE-312 Cleartext Storage of Sensitive Information | A04 | A06 | V14 |

TLS configuration itself belongs to audit-infra.

## Front-end, configuration, integrity

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| CORS reflecting any origin (or `null`) with credentials. A literal `*` with credentials is refused by browsers: not a finding | CWE-942 Permissive Cross-domain Security Policy with Untrusted Domains | A05 | A02 | V3 |
| `postMessage` handler that does not check `event.origin` | CWE-346 Origin Validation Error | A07 | A07 | V3 |
| Third-party script without SRI | CWE-353 Missing Support for Integrity Check | A08 | A08 | V3 |
| Script loaded from an origin the team does not control | CWE-829 Inclusion of Functionality from Untrusted Control Sphere | A08 | A08 | V3 |
| Missing or permissive CSP (`unsafe-inline`, `*`) | CWE-1021 Improper Restriction of Rendered UI Layers or Frames when the gap is framing (clickjacking); otherwise CWE-693 Protection Mechanism Failure, a last resort: MITRE marks this Pillar "discouraged" for mapping | A04 for 1021 | A06 (both) | V3 |
| Source maps or source with secrets served in production | CWE-540 Inclusion of Sensitive Information in Source Code | A01 | A01 | V13 |
| `window.open(url)` to an untrusted site without `noopener`, or a link with `rel="opener"`. A plain `<a target="_blank">` is **not** a finding: current browsers imply `noopener` | CWE-1022 Use of Web Link to Untrusted Target with window.opener Access | (A04) | A06 | V3 |
| Webhook accepted without verifying its signature | CWE-345 Insufficient Verification of Data Authenticity | A08 | A08 | V4 API and Web Service |
| Debug mode or debug endpoint left on in production | CWE-489 Active Debug Code | (A05) | A02 | V13 |
| Default credentials left in place (`admin`/`admin`) | CWE-1392 Use of Default Credentials | (A07) | A07 | V6 |

## Logging, errors, supply chain, LLM

| Finding class | CWE | 2021 | 2025 | ASVS 5.0 |
|---|---|---|---|---|
| Secrets or personal data written to logs | CWE-532 Insertion of Sensitive Information into Log File | A09 | A09 | V16 Security Logging and Error Handling |
| User input written to logs unescaped (log forging) | CWE-117 | A09 | A09 | V16 |
| Security events (login failure, access denied) not logged | CWE-778 Insufficient Logging | A09 | A09 | V16 |
| Stack trace, SQL error, internal path returned to the client | CWE-209 Generation of Error Message Containing Sensitive Information | A04 | A10 | V16 |
| Dependency with a known vulnerability | CWE-1395 Dependency on Vulnerable Third-Party Component | (A06) | A03 | V15 |
| Unmaintained dependency | CWE-1104 Use of Unmaintained Third Party Components | A06 | A03 | V15 |
| Code or package fetched without integrity check | CWE-494 Download of Code Without Integrity Check | A08 | A08 | V15 |
| Malicious package installed | CWE-506 Embedded Malicious Code | (A08) | A08 | V15 |
| Prompt injection | CWE-1427 Improper Neutralization of Input Used for LLM Prompting | (A03) | (A05) | (none) |

For LLM integrations also cite the OWASP Top 10 for LLM Applications 2025:
LLM01 Prompt Injection, LLM02 Sensitive Information Disclosure, LLM05
Improper Output Handling, LLM06 Excessive Agency, LLM07 System Prompt
Leakage. Model output rendered as HTML is plain CWE-79; a tool the model can
call without the user's rights being checked is plain CWE-862. Prefer those
precise labels to a generic "prompt injection".

## Labelling a dependency finding

A vulnerable dependency has two CWEs: the weakness inside the library (given
by the advisory, `database_specific.cwe_ids`) and the fact of depending on
it. Report the advisory's CWE as primary and the OWASP supply-chain category
as the class. Example: lodash CVE-2019-10744 is "CWE-1321, A06:2021 /
A03:2025", not CWE-1395 alone.
